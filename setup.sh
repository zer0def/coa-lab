#! /bin/bash

# Debug options to enable bash trace with output to file descriptor 1 (common output)
BASH_XTRACEFD="1"
PS4='$LINENO: '
set -x

export LC_TYPE="UTF-8"
export LANG="en-US.UTF-8"
export LC_ALL="C"

# Set all Global Variables, defined in vars.sh
cp /vagrant/vars.sh /home/vagrant
cp /vagrant/install-openstack.sh /home/vagrant
cp /vagrant/configure-lab.sh /home/vagrant
mkdir -p /home/vagrant/labs
cp /vagrant/labs/* /home/vagrant/labs
source /home/vagrant/vars.sh

source /etc/os-release
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y cloud-guest-utils crudini "linux-generic-hwe-${VERSION_ID}" lvm2 zram-config
systemctl enable zram-config
growpart /dev/sda 2
resize2fs /dev/sda2

crudini --set /etc/default/grub "" GRUB_CMDLINE_LINUX '"net.ifnames=0 biosdevname=0 nosplash verbose"'
update-grub

rm -I /etc/netplan/*
cat <<- EOF > /etc/netplan/50-vagrant.yaml
network:
  version: 2
  ethernets:
    ${INTERNET_INTERFACE_NAME}:
      dhcp4: true
      addresses: [${CONTROLLER_CIDR}]
      nameservers:
        addresses: [${CONTROLLER_NAMESERVERS}]
    ${PROVIDER_INTERFACE_NAME}:
      dhcp4: false
    ${NAT_INTERFACE_NAME}:
      dhcp4: false
EOF

pvcreate "${OS_DATA_DEV:-/dev/sdc}"
vgcreate "${OS_DATA_VG}" "${OS_DATA_DEV:-/dev/sdc}"
lvcreate -L 2G -n swift11 "${OS_DATA_VG}"
lvcreate -L 2G -n swift12 "${OS_DATA_VG}"
lvcreate -L 2G -n swift21 "${OS_DATA_VG}"
lvcreate -L 2G -n swift22 "${OS_DATA_VG}"
lvcreate -L 30G -n cinder-vols1 "${OS_DATA_VG}"
lvcreate -L 5G -n cinder-vols2 "${OS_DATA_VG}"

reboot
