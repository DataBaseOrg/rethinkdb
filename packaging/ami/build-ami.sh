#!/bin/bash

set -eu

usage () {
    echo "$0 [options]"
    echo "Build a RethinkDB AMI"
}

defaults () {
    ssh_only_group=ssh-only-vpc
    ami_group=rethinkdb-cluster
    ssh_control_path='~/.ssh/master-%l-%r@%h:%p'
    ssh_user=ubuntu
    setup_files=$(dirname "$0")/build-ami-files
    ami_name=rethinkdb
    ami_description="RethinkDB"
    ssh_key_name=

    # See http://cloud-images.ubuntu.com/locator/ec2/ for a list of official Ubuntu AMI
    base_ami=ami-cc3b3ea4 # Ubuntu Trusty 14.04 amd64 hvm:ebs-ssd 20150417
}

parseopts () {
    while [[ $# -gt 0 ]]; do
        local arg=$1
        shift
        case $arg in
            --ami-name) ami_name=$1; shift ;;
            --vpc-subnet) vpc_subnet=$1; shift ;;
            *) die "Unknown argument $arg" ;;
        esac
    done
}

main () {
    defaults
    parseopts "$@"
    check_env
    echo "Starting RethinkDB AMI creation process"
    local key
    key=$(find_usable_key)
    echo "Using key $key"
    local instance_id instance_address
    find_vpc_subnet vpc subnet
    echo "Using VPC subnet $subnet in VPC $vpc"
    ssh_only_group_id=$(ensure_ssh_only_group "$vpc")
    echo "Using security group $ssh_only_group_id"
    launch_instance_ephemeral "$base_ami" "$ssh_only_group_id" t2.micro "$key" "$subnet" instance_id instance_address

    scp_to "$instance_address" "$setup_files" "/tmp/build-ami"
    run "$instance_address" 'cd /tmp/build-ami && sudo bash setup.sh'
    run "$instance_address" rm -rf /tmp/build-ami

    run "$instance_address" 'sudo bash -c "rm /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys"'

    # gid=$(ensure_ami_group "$vpc")

    echo "Creating AMI named $ami_name..."

    local ami_id
    create_rethinkdb_ami "$instance_id" ami_id
    at_exit echo "Created AMI $ami_id"
}

# find_vpc_subnet <&vpc_id> <&subnet_id>
find_vpc_subnet () {
    out_vpc=$1
    out_subnet=$2
    if [[ -n "${vpc_subnet:-}" ]]; then
        ids="$vpc_subnet"
    else
        ids=$(ec2-describe-subnets | grep ^SUBNET | awk '{print$2":"$4}')
        set -- $ids
        if [[ "$#" = 0 ]]; then
            die "no VPC subnets found. Please create one"
        fi
        if [[ "$#" != 1 ]]; then
            echo "Multiple subnets found. Use the --vpc-subnet flag to select one:" >&2
            printf "%s\n" "$@" >&2
            die "aborting"
        fi
    fi
    eval "$out_vpc=$(printf %q "$(echo "$ids" | cut -f 2 -d :)")"
    eval "$out_subnet=$(printf %q "$(echo "$ids" | cut -f 1 -d :)")"
}

# stop_instance <id>
stop_instance () {
    ec2-stop-instances $1 >/dev/null
    while true; do
        local out
        out=$(ec2-describe-instances $1)
        local status
        status=$(echo "$out" | grep ^INSTANCE | cut -f 6)
        if [[ "$status" == stopped ]]; then
            break
        else
            sleep 1
        fi
    done
}

# create_rethinkdb_ami <instance_id> <&ami_id>
create_rethinkdb_ami () {
    echo "Stopping the instance $1"
    stop_instance "$1"
    local out
    out=$(
        ec2-create-image $1 \
        --name "$ami_name" \
        --description "$ami_description"
        # --block-device-mapping ""
    )
    local _ami_id
    _ami_id=$(echo "$out" | cut -f 2)
    echo -n "Building AMI $_ami_id ."
    while true; do
        out=$(ec2-describe-images "$_ami_id")
        local status
        status=$(echo "$out" | grep ^IMAGE | cut -f 5)
        case "$status" in
            failed) error "image creation failed" ;;
            pending) echo -n ' .'; sleep 5 ;;
            available) echo ' done'; eval "$2=$(printf %q "$_ami_id")"; break ;;
            *) error "unknown AMI status $status" ;;
        esac
    done
}

check_env () {
    [ -n "${EC2_URL:-}" ] || error "\$EC2_URL must contain the ec2 region url (e.g. https://ec2.us-east-1.amazonaws.com)"
    [ -n "${EC2_PRIVATE_KEY:-}" ] || error "\$EC2_PRIVATE_KEY must contain the path to your ec2 private key file"
    [ -n "${EC2_CERT:-}" ] || error "\$EC2_CERT must contain the path to your ec2 certificate"
    [ -n "${SSH_AUTH_SOCK:-}" ] || error "ssh-agent must be setup and loaded with your ec2 ssh key"
}

# error <message>
error () {
    die "build-ami: error: $1"
}

# die <message>
die () {
    echo "$@" >&2
    exit 1
}

# at_exit <cmd> <args...>
at_exit () {
    local cmd=
    while [[ $# -gt 0 ]]; do
        cmd="$cmd $(printf %q "$1")"
        shift
    done
    at_exit_cmds="${at_exit_cmds:-true}; $cmd"
    trap "$at_exit_cmds" EXIT
}

# exists_group <name> <vpc>
exists_group () {
    line=$(ec2-describe-group | grep "$1" | grep "$2") \
        && { echo "$line" | awk '{print$2}'; }
}

# create_group <name> <description> <vpc>
create_group () {
    local out
    out=$(ec2-create-group "$1" -d "$2" --vpc "$3")
    echo "$out" | cut -f 2
}

# group_authorize_tcp_port <name> <port>
group_authorize_tcp_port () {
    ec2-authorize "$1" -P tcp -p "$2" >/dev/null
}

# group_authorize_icmp <name>
group_authorize_icmp () {
    ec2-authorize "$1" -P icmp -t -1:-1 -s 0.0.0.0/0 >/dev/null
}

# group_authorize_group_id <name> <id>
group_authorize_group_id () {
    ec2-authorize "$1" -P tcp -p -1 -o "$2"
}

# ensure_ssh_only_group <vpc>
ensure_ssh_only_group () {
    if ! exists_group "$ssh_only_group" "$1"; then
        echo "Creating security group '$ssh_only_group'" >&2
        group=$(create_group "$ssh_only_group" "Only allow ssh (port 22)" "$1")
        group_authorize_tcp_port "$group" 22
        echo "$group"
    fi
}

# ensure_ami_group <vpc>
ensure_ami_group () {
    if ! exists_group "$ami_group" "$1"; then
        echo "Creating security group '$ami_group'" >&2
        local group_id
        group_id=$(create_group "$ami_group" "RethinkDB Cluster" "$1")
        group_authorize_tcp_port "$group_id" 22
        group_authorize_tcp_port "$group_id" 80
        group_authorize_tcp_port "$group_id" 443
        group_authorize_tcp_port "$group_id" 28015
        group_authorize_icmp "$group_id"
        group_authorize_group_id "$group_id" "group_id"
    fi
}

# find_key_name <fingerprint>
find_key_name () {
    local key
    key=$(ec2-describe-keypairs --filter fingerprint="$1" | awk '{print $2}')
    [ -n "$key" ] || return 1
    echo "$key"
}

list_local_keys () {
    local list
    list=`ssh-add -l` || error "unable to list keys with 'ssh-add -l'"
    echo "$list" | awk '{print $3}' | xargs -n 1 ec2-fingerprint-key 2>/dev/null || true
    echo "$list" | awk '{print $2}'
}

find_usable_key () {
    if [[ -n "$ssh_key_name" ]]; then
        echo "$ssh_key_name"
        return
    fi
    local fingerprint
    local name
    for fingerprint in `list_local_keys`; do
        if name=`find_key_name "$fingerprint"`; then
            ssh_key_name=$name
            echo "$name"
            return
        fi
    done
    return 1
}

# launch_instance_ephemeral <ami> <group> <machine> <key> <vpc> [<&id> <&address>]
launch_instance_ephemeral () {
    echo "Launching base instance from ami $1 in group $2 on machine $3 with key $4"
    local out
    out=$(ec2-run-instances "$1" -g "$2" -t "$3" -k "$4" --subnet "$5") || die "Failed to launch instance: $out"
    local _instance_id
    _instance_id=$(echo "$out" | grep ^INSTANCE | cut -f 2)
    at_exit echo Terminating instance "$_instance_id"
    at_exit ec2-terminate-instances "$_instance_id"
    local _instance_address
    echo "Waiting for instance $_instance_id to start.."
    while true; do
        out=$(ec2-describe-instances "$_instance_id")
        _instance_address=$(echo "$out" | grep ^INSTANCE | cut -f 4)
        local status
        status=$(echo "$out" | grep ^INSTANCE | cut -f 6)
        echo "Instance status: $status (no public address available)"
        if test -n "$_instance_address"; then
            break
        else
            sleep 5
        fi
    done
    start_ssh_master "$_instance_address"
    eval "${6:-instance_id}=$(printf %q "$_instance_id")"
    eval "${7:-instance_address}=$(printf %q "$_instance_address")"
}

# start_ssh_master <address> [<retries=20>] [<wait=5>]
start_ssh_master () {
    local address=$1
    local retries=${2:-20}
    local wait=${3:-5}
    while [[ $retries != 0 ]]; do
        echo "Attempting to connect to $address ($retries tries left)"
        if ssh -M -o StrictHostKeyChecking=no -o ControlPath="$ssh_control_path" -o ControlPersist=yes -o ConnectTimeout=5 "$ssh_user@$address" true; then
            # at_exit echo Stopping ssh master
            # at_exit ssh -o ControlPath="$ssh_control_path" "$ssh_user@$address" -O exit
            echo "Connected to $address"
            return
        fi
        sleep "$wait"
        retries=$((retries-1))
    done
    error "Could not ssh to $address"
}

# run <instance_address> [<cmd> <args...>]
run () {
    local address=$1
    shift
    echo "[$ssh_user@$address] $*"
    ssh "$ssh_user@$address" -o ControlPath="$ssh_control_path" "$@"
}

# scp_to <instance_address> <local_file> <remote_file>
scp_to () {
    scp -r -o ControlPath="$ssh_control_path" "$2" "$ssh_user@$1:$3"
}

main "$@"
