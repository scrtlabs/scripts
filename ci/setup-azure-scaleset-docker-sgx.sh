#!/bin/bash

# 1 = username
# 2 = moniker
# 3 = chainid
# 4 = persistent peers
# 5 = rpc url (to get genesis file from)
# 6 = registration service (our custom registration helper)
# 7 = docker compose file location

export DEBIAN_FRONTEND=noninteractive

USER=azureuser
HOME=/home/$USER

sudo /bin/date +%H:%M:%S > $HOME/install.progress.txt

# Original script:
#
# Script Name: vm-disk-utils.sh
# Author: Trent Swanson - Full Scale 180 Inc github:(trentmswanson)
# https://github.com/Azure/azure-quickstart-templates/blob/master/shared_scripts/ubuntu/vm-disk-utils-0.1.sh


# Base path for data disk mount points
DATA_BASE="/datadisks"
# Mount options for data disk
MOUNT_OPTIONS="noatime,nodiratime,nodev,noexec,nosuid,nofail"

# log() was missing, added a basic one
log()
{
    echo "$1"
}

is_partitioned() {
    OUTPUT=$(partx -s ${1} 2>&1)
    egrep "partition table does not contains usable partitions|failed to read partition table" <<< "${OUTPUT}" >/dev/null 2>&1
    if [ ${?} -eq 0 ]; then
        return 1
    else
        return 0
    fi    
}

has_filesystem() {
    DEVICE=${1}
    OUTPUT=$(file -L -s ${DEVICE})
    grep filesystem <<< "${OUTPUT}" > /dev/null 2>&1
    return ${?}
}

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # The disk will be considered a candidate for partitioning
        # and formatting if it does not have a sd?1 entry or
        # if it does have an sd?1 entry and does not contain a filesystem
        is_partitioned "${DEV}"
        if [ ${?} -eq 0 ];
        then
            has_filesystem "${DEV}1"
            if [ ${?} -ne 0 ];
            then
                RET+=" ${DEV}"
            fi
        else
            RET+=" ${DEV}"
        fi
    done
    echo "${RET}"
}

get_next_mountpoint() {
    DIRS=$(ls -1d ${DATA_BASE}/disk* 2>/dev/null| sort --version-sort)
    MAX=$(echo "${DIRS}"|tail -n 1 | tr -d "[a-zA-Z/]")
    if [ -z "${MAX}" ];
    then
        echo "${DATA_BASE}/disk1"
        return
    fi
    IDX=1
    while [ "${IDX}" -lt "${MAX}" ];
    do
        NEXT_DIR="${DATA_BASE}/disk${IDX}"
        if [ ! -d "${NEXT_DIR}" ];
        then
            echo "${NEXT_DIR}"
            return
        fi
        IDX=$(( ${IDX} + 1 ))
    done
    IDX=$(( ${MAX} + 1))
    echo "${DATA_BASE}/disk${IDX}"
}

add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=\"${UUID}\"\t${MOUNTPOINT}\text4\t${MOUNT_OPTIONS}\t1 2"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

do_partition() {
# This function creates one (1) primary partition on the
# disk, using all available space
    _disk=${1}
    _type=${2}
    if [ -z "${_type}" ]; then
        # default to Linux partition type (ie, ext3/ext4/xfs)
        _type=83
    fi
    (echo n; echo p; echo 1; echo ; echo ; echo ${_type}; echo w) | fdisk "${_disk}"

#
# Use the bash-specific $PIPESTATUS to ensure we get the correct exit code
# from fdisk and not from echo
if [ ${PIPESTATUS[1]} -ne 0 ];
then
    echo "An error occurred partitioning ${_disk}" >&2
    echo "I cannot continue" >&2
    exit 2
fi
}
#end do_partition

scan_partition_format()
{
    log "Begin scanning and formatting data disks"

    DISKS=($(scan_for_new_disks))

	if [ "${#DISKS}" -eq 0 ];
	then
	    log "No unpartitioned disks without filesystems detected"
	    return
	fi
	echo "Disks are ${DISKS[@]}"
	for DISK in "${DISKS[@]}";
	do
	    echo "Working on ${DISK}"
	    is_partitioned ${DISK}
	    if [ ${?} -ne 0 ];
	    then
	        echo "${DISK} is not partitioned, partitioning"
	        do_partition ${DISK}
	    fi
	    PARTITION=$(fdisk -l ${DISK}|grep -A 1 Device|tail -n 1|awk '{print $1}')
	    has_filesystem ${PARTITION}
	    if [ ${?} -ne 0 ];
	    then
	        echo "Creating filesystem on ${PARTITION}."
	        mkfs -j -t ext4 ${PARTITION}
	    fi
	    MOUNTPOINT=$(get_next_mountpoint)
	    echo "Next mount point appears to be ${MOUNTPOINT}"
	    [ -d "${MOUNTPOINT}" ] || mkdir -p "${MOUNTPOINT}"
	    read UUID FS_TYPE < <(blkid -u filesystem ${PARTITION}|awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
	    add_to_fstab "${UUID}" "${MOUNTPOINT}"
	    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
	    mount "${MOUNTPOINT}"
	done
}


# Create Partitions
DISKS=$(scan_for_new_disks)
scan_partition_format

echo "Creating tmp folder for aesm" >> $HOME/install.progress.txt

# Aesm service relies on this folder and having write permissions
# shellcheck disable=SC2174
mkdir -p -m 777 /tmp/aesmd
chmod -R -f 777 /tmp/aesmd || sudo chmod -R -f 777 /tmp/aesmd || true

echo "Installing docker" >> $HOME/install.progress.txt

sudo apt update
sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu bionic stable"
sudo apt update
sudo apt install docker-ce -y

DOCKER_DATA_PATH="${DATA_BASE}/disk1/docker"

sudo chown $USER:$USER $DOCKER_DATA_PATH

echo "Setting docker data path to: $DOCKER_DATA_PATH" >> $HOME/install.progress.txt

sudo systemctl stop docker

sudo sed -i 's!--containerd!--data-root /datadisks/disk1/docker --containerd!g' /lib/systemd/system/docker.service

sudo cp -axT /var/lib/docker $DOCKER_DATA_PATH

echo "Adding user $USER to docker group" >> $HOME/install.progress.txt
sudo service docker start
sudo systemctl enable docker
sudo groupadd docker
sudo usermod -aG docker $USER

echo "Installing docker-compose" >> $HOME/install.progress.txt
# systemctl status docker
sudo curl -L https://github.com/docker/compose/releases/download/v2.12.1/docker-compose-"$(uname -s)"-"$(uname -m)" -o /usr/local/bin/docker-compose

sudo chmod +x /usr/local/bin/docker-compose

echo "Creating docker compose file" >> $HOME/install.progress.txt


file=$HOME/docker-compose.yaml
if [ ! -e "$file" ]
then
  {
    echo "version: '3'"
    printf '\n'
    echo "services:
  aesm:
    image: enigmampc/aesm
    devices:
      - /dev/sgx/enclave
      - /dev/sgx/provision
    volumes:
      - /tmp/aesmd:/var/run/aesmd
    stdin_open: true
    tty: true
    environment:
      - http_proxy
      - https_proxy"
  } | sudo tee $HOME/docker-compose.yaml
fi

echo "Created: " >> $HOME/install.progress.txt
cat $HOME/docker-compose.yaml >> $HOME/install.progress.txt

UBUNTUVERSION=$(lsb_release -r -s | cut -d '.' -f 1)
PSW_PACKAGES='libsgx-enclave-common libsgx-aesm-launch-plugin libsgx-aesm-quote-ex-plugin libsgx-urts sgx-aesm-service libsgx-uae-service autoconf libtool make'

if (($UBUNTUVERSION < 16)); then
	echo "Your version of Ubuntu is not supported. Must have Ubuntu 16.04 and up. Aborting installation script..."
	exit 1
elif (($UBUNTUVERSION < 18)); then
	DISTRO='xenial'
	OS='ubuntu16.04-server'
elif (($UBUNTUVERSION < 20)); then
	DISTRO='bionic'
	OS='ubuntu18.04-server'
else
	DISTRO='focal'
	OS='ubuntu20.04-server'  
fi

# Remount /dev as exec, also at system startup
sudo tee /etc/systemd/system/remount-dev-exec.service >/dev/null <<EOF
[Unit]
Description=Remount /dev as exec to allow AESM service to boot and load enclaves into SGX

[Service]
Type=oneshot
ExecStart=/bin/mount -o remount,exec /dev
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable remount-dev-exec
sudo systemctl start remount-dev-exec

echo "\n\n###############################################" >> $HOME/install.progress.txt
echo "#####       Installing Intel SGX PSW          #####" >> $HOME/install.progress.txt
echo "###############################################\n\n" >> $HOME/install.progress.txt

# Add Intel's SGX PPA
echo "deb [arch=amd64] https://download.01.org/intel-sgx/sgx_repo/ubuntu $DISTRO main" |
   sudo tee /etc/apt/sources.list.d/intel-sgx.list
wget -qO - https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key |
   sudo apt-key add -
sudo apt update

# Install libprotobuf
if (($UBUNTUVERSION > 18)); then
   sudo apt install -y gdebi
   # Install all the additional necessary dependencies (besides the driver and the SDK)
   # for building a rust enclave
   wget -O /tmp/libprotobuf10_3.0.0-9_amd64.deb http://ftp.br.debian.org/debian/pool/main/p/protobuf/libprotobuf10_3.0.0-9_amd64.deb
   yes | sudo gdebi /tmp/libprotobuf10_3.0.0-9_amd64.deb
else
   PSW_PACKAGES+=' libprotobuf-dev'
fi

sudo apt install -y $PSW_PACKAGES

################################################################
# Configure to auto start at boot					    #
################################################################
#file=/etc/init.d/sgx-runner
#if [ ! -e "$file" ]
#then
#  {
#    echo '#!/bin/sh'
#    printf '\n'
#    # shellcheck disable=SC2016
#    printf '### BEGIN INIT INFO
# Provides:       sgx-runner
# Required-Start:    $all
# Required-Stop:     $local_fs $network $syslog $named $docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: starts sgx runner
# Description:       starts sgx runner running in docker
### END INIT INFO\n\n'
#    printf 'mkdir -p -m 777 /tmp/aesmd\n'
#    printf 'chmod -R -f 777 /tmp/aesmd || sudo chmod -R -f 777 /tmp/aesmd || true\n'
#    printf '\n'
 #   printf 'docker-compose -f /home/bob/docker-compose.yaml up -d\n'
#  } | sudo tee /etc/init.d/sgx-runner

#	sudo chmod +x /etc/init.d/sgx-runner
#	sudo update-rc.d sgx-runner defaults
#fi

#docker-compose -f /home/bob/docker-compose.yaml up -d

# restart docker service
sudo systemctl daemon-reload
sudo service docker stop
sudo service docker start

echo "Sgx pipeline runner has been setup successfully and is running..." >> $HOME/install.progress.txt
