#!/bin/sh

set -e

[ -n "${DEBUG}" ] && set -x

# General stuff
WORKDIR=${PWD}/.workdir
SSH_PUBLIC_KEY_FILE=${PUBLIC_KEY_FILE:-${HOME}/.ssh/id_rsa.pub}
CENTOS_USERNAME=centos
IP_PREFIX="192.168.122"

# Master configuration
CENTOS_MASTER_COUNT=${MASTER_COUNT:-3}
CENTOS_MASTER_PREFIX=master
CENTOS_MASTER_RAM=${MASTER_RAM:-1024}
CENTOS_MASTER_CPU=${MASTER_CPU:-1}

# Node Configuration
CENTOS_NODE_COUNT=${NODE_COUNT:-0}
CENTOS_NODE_PREFIX=node
CENTOS_NODE_RAM=${NODE_RAM:-2048}
CENTOS_NODE_CPU=${NODE_CPU:-1}

# General configuration
CENTOS_DISK_IMAGE=${WORKDIR}/centos.qcow2
META_DATA_TEMPLATE=meta-data.yaml.j2
USER_DATA_TEMPLATE=user-data.yaml.j2
QEMU_NETWORK=default
CENTOS_IMAGE_URL=https://cloud.centos.org/centos/8/x86_64/images/CentOS-8-GenericCloud-8.1.1911-20200113.3.x86_64.qcow2

prepare() {
   # Prepare environment
   mkdir -p ${WORKDIR}
   [ -f "${CENTOS_DISK_IMAGE}" ] || wget ${CENTOS_IMAGE_URL} -O ${CENTOS_DISK_IMAGE} 
}

create_disks() {
   # Update disks with CENTOS images and cloud configs
    local count=${1}
    local prefix=${2}
    for i in $(seq 0 $(expr ${count} - 1)); do
        cp ${CENTOS_DISK_IMAGE} $(get_filename ${i} ${prefix})
        cp $(user_data_file ${i} ${prefix}) user-data
        cp $(meta_data_file ${i} ${prefix}) meta-data
        genisoimage -output $(get_isoname ${i} ${prefix}) \
            -volid cidata -joliet -rock user-data meta-data
        rm user-data meta-data
    done
}

run_vms() {
    # Create cluster VMs
    local count=${1}
    local prefix=${2}
    local vnc_start=$([ "${prefix}" = "master" ] && echo "6100" || echo "6200")
    local ram=$([ "${prefix}" = "master" ] && echo "${CENTOS_MASTER_RAM}" || echo "${CENTOS_NODE_RAM}")
    local cpu=$([ "${prefix}" = "master" ] && echo "${CENTOS_MASTER_CPU}" || echo "${CENTOS_NODE_CPU}")
    for i in $(seq 0 $(expr ${count} - 1)); do
        local disk=$(get_filename ${i} ${prefix})
        local iso_name=$(get_isoname ${i} ${prefix})
        virt-install \
            -n ${prefix}-${i} \
            --description "CentOS Kubernetes Cluster. Host ${prefix}-${i}" \
            --os-type=Linux \
            --os-variant=centos7.0 \
            --ram=${ram} \
            --vcpus=${cpu} \
            --import \
            --noautoconsole \
            --disk ${disk},format=qcow2,bus=virtio \
            --disk ${iso_name},device=cdrom \
            --graphics vnc,port=$(expr ${vnc_start} + ${i}),listen=0.0.0.0 \
            --console pty,target_type=serial \
            --network network=${QEMU_NETWORK},model=virtio,mac=$(mac_address ${i} ${prefix}) 
        sleep 1
    done
}

generate_configs() {
    # Generate cloud config file for CENTOS hosts
    local count=${1}
    local prefix=${2}
    local ssh_key="$(cat ${SSH_PUBLIC_KEY_FILE})"
    for i in $(seq 0 ${count}); do
        sed -e "s|{{ ssh_key }}|${ssh_key}|" ${USER_DATA_TEMPLATE} \
          | sed -e "s|{{ username }}|${CENTOS_USERNAME}|" \
          >$(user_data_file ${i} ${prefix})
        
        sed -e "s|{{ hostname }}|${prefix}-${i}|g" ${META_DATA_TEMPLATE} \
          >$(meta_data_file ${i} ${prefix})
     done
}

user_data_file() {
    # Return user data filename for particular VM
    local num=${1}
    local prefix=${2}
    echo ${WORKDIR}/${prefix}-${num}-user-data.yaml
}

meta_data_file() {
    # Return meta data filename for particular VM
    local num=${1}
    local prefix=${2}
    echo ${WORKDIR}/${prefix}-${num}-meta-data.yaml
}

get_filename() {
    # Return filename of disk image for particular VM
    local num=${1}
    local prefix=${2}
    echo ${WORKDIR}/${prefix}-${num}.qcow2
}

get_isoname() {
    # Return filename of ISO image for particular VM
    local num=${1}
    local prefix=${2}
    echo ${WORKDIR}/${prefix}-${num}-cloud-init.iso
}

remove_vms() {
    # Remove created VMs, as well as disk images and configs
    local count=${1}
    local prefix=${2}
    local red="\e[31m"
    local def="\e[39m"
    for i in $(seq 0 $(expr ${count} - 1)); do
        printf "${red}Removing ${prefix}-${i}\n${def}"
        virsh destroy ${prefix}-${i} | true
        virsh undefine ${prefix}-${i} | true
        rm -f $(get_filename ${i} ${prefix}) \
              $(get_isoname ${i} ${prefix}) \
              $(meta_data_file ${i} ${prefix}) \
              $(user_data_file ${i} ${prefix}) \
           | true
        printf "${red} ${prefix}-${i} removed\n${def}"
    done
}

mac_address() {
    # Define MAC address for particular host, use QEMU oui
    local num=${1}
    local prefix=${2}
    local start_mac=$([ "${prefix}" = "master" ] && echo "16" || echo "100")
    local mac_bits=$(expr ${start_mac} + ${num})
    local mac_addr=52:54:00:00:00:$(printf "%x" ${mac_bits})
    echo ${mac_addr}
}

vm_ip() {
    # Define IP address for particular host
    local num=${1}
    local prefix=${2}
    local start_ip=$([ "${prefix}" = "master" ] && echo "100" || echo "200")
    local last_octet=$(expr ${start_ip} + ${num})
    local ip_prefix=${IP_PREFIX}
    local ip_addr=${ip_prefix}.${last_octet}
    echo ${ip_addr}    
}

network_up() {
    configure_network $1 $2 add-last
}

network_destroy() {
    configure_network $1 $2 delete
}

configure_network() {
    # Manage IP DHCP bindings
    local num=${1}
    local prefix=${2}
    local action=${3}
    local start_with=$([ "${prefix}" = "master" ] && echo "100" || echo "200")
    for i in $(seq 0 $(expr ${count} - 1)); do
        local mac_addr=$(mac_address ${i} ${prefix})
        local ip_addr=$(vm_ip ${i} ${prefix})
        virsh net-update ${QEMU_NETWORK} ${action} ip-dhcp-host "<host mac=\"${mac_addr}\" ip=\"${ip_addr}\"/>" --live --config --parent-index 0
    done
}

error_fail() {
    # Print error message and exit
    printf "\e[31m ${1}\n"
    exit 1
}

up() {
    # Create, start, and configure VMs of the Kubernetes cluster
    prepare
    virsh net-start ${QEMU_NETWORK} || true
    for type in master node; do
        local count=$([ "${type}" = "master" ] && echo "${CENTOS_MASTER_COUNT}" || echo "${CENTOS_NODE_COUNT}")
        generate_configs ${count} ${type}
        create_disks ${count} ${type}
        network_up ${count} ${type}
        run_vms ${count} ${type}
    done
}

destroy() {
    # Remove VMs of the Kubernetes cluster
    for type in master node; do
        local count=$([ "${type}" = "master" ] && echo "${CENTOS_MASTER_COUNT}" || echo "${CENTOS_NODE_COUNT}")
        remove_vms ${count} ${type}
        network_destroy ${count} ${type}
    done
    virsh net-destroy ${QEMU_NETWORK}
}

inventory() {
    # Print hosts inventory in json format
    echo '{'
    for prefix in ${CENTOS_MASTER_PREFIX} ${CENTOS_NODE_PREFIX}; do
        groups=$(
          [ -n "${groups}" ] && echo "${groups},"
          hosts=$(virsh net-dhcp-leases ${QEMU_NETWORK} | grep ipv4 | grep ${prefix} | \
                  awk '{print $5}' | awk -F'/' '{print "\"" $1 "\","}')
          echo "\"${prefix}\":" '{"hosts" : ['
          [ -n "${hosts}" ] && echo "${hosts%?}"
          echo '],'
          echo '"vars": {'
          echo '"ansible_ssh_user":' "\"${CENTOS_USERNAME}\"," 
          echo '"ansible_ssh_extra_args": "-o StrictHostKeyChecking=no"'
          echo '"master_load_balancer": ' "\"${IP_PREFIX}.50\""
          echo "} }"
          )
     done
     echo "${groups} }"
}

print_help() {
    # Print help message
    printf "
Manage Kubernetes cluster based on CENTOS that is run by KVM.

Usage: $0 <action>
  Action may be:
    up          create a Kubernetes cluster
    destroy     turn off the cluser and remove VMs
    inv         print VM addresses in format of Ansible dynamic inventory

Environment variables that may be used for configuration by exporting:

    # Master configuration
    MASTER_COUNT         number of master VMs (default: 1)
    MASTER_RAM           amount of RAM im megabytes for master VM (default: 1024)
    MASTER_CPU           mumber of CPU cores for master VM (default: 1)

    # Node Configuration
    NODE_COUNT           number of node VMs (default: 1)
    NODE_RAM             amount of RAM im megabytes for node VM (default: 2048)
    NODE_CPU             mumber of CPU cores for node VM (default: 1)

    # Debug options
    DEBUG                debug mode

Example:
  $ export NODE_COUNT=3
  $ $0 up
"
}

case $1 in
  inv)
    inventory
    ;;
  up)
    up
    ;;
  destroy)
    destroy
    ;;
  *)
    print_help
    ;;
esac
