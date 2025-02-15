#! /bin/bash

# Debuging options for this script, tracing output is sent to file descriptor 2 (where typical error messages go)
BASH_XTRACEFD="2"
PS4='$LINENO: '
set -x


export LC_TYPE="UTF-8"
export LANG="en-US.UTF-8"
export LC_ALL="C"

# Set all Global Variables, defined in vars.sh

source vars.sh

# Create proper /etc/hosts file

cat <<- EOF > /etc/hosts
127.0.0.1   localhost
${CONTROLLER_IP}    ${CONTROLLER_HOSTNAME}
EOF

export DEBIAN_FRONTEND=noninteractive

# from OpenStack Packages for Ubuntu https://docs.openstack.org/install-guide/environment-packages-ubuntu.html

case "$(lsb_release -cs)" in
  bionic) OS_RELEASE=ussuri;;
  focal)  OS_RELEASE=xena;;  # codename y
esac

echo "Starting installation of OpenStack Packages for Ubuntu"
apt update
apt install -y software-properties-common
add-apt-repository -y "cloud-archive:${OS_RELEASE}"
apt update -y && apt dist-upgrade -y
apt install -y python3-openstackclient

# from SQL Database for Ubuntu https://docs.openstack.org/install-guide/environment-sql-database-ubuntu.html

echo "Starting installation of SQL Database for Ubuntu"
# workaround for Neutron bug in cloud-archive for bionic/train: https://bugs.launchpad.net/cloud-archive/+bug/1841907
apt -y install curl gnupg
curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/mariadb-archive-keyring.gpg
echo deb http://mirror2.hs-esslingen.de/mariadb/repo/10.6/ubuntu $(lsb_release -cs) main > /etc/apt/sources.list.d/mariadb.list
apt update
apt install -y mariadb-server python3-pymysql
[ "$(lsb_release -cs)" = "focal" ] || apt install -y python-pymysql

cat <<- EOF > /etc/mysql/mariadb.conf.d/99-openstack.cnf
[mysqld]
bind-address = ${CONTROLLER_IP}

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

service mysql restart
mysql_secure_installation <<- EOF

n
n
y
n
y
y
EOF

# from Message Queue for Ubuntu https://docs.openstack.org/install-guide/environment-messaging-ubuntu.html

echo "Starting installation of Message queue for Ubuntu"

apt install -y rabbitmq-server
rabbitmqctl add_user openstack "${RABBIT_PASS}"
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

# from Memcached for Ubuntu https://docs.openstack.org/install-guide/environment-memcached-ubuntu.html

echo "Starting installation of Memcached for Ubuntu"

apt install -y memcached python3-memcache
[ "$(lsb_release -cs)" = "focal" ] || apt install -y python-memcache
sed -i "s/127.0.0.1/${CONTROLLER_IP}/g" /etc/memcached.conf
service memcached restart

# from Etcd for Ubuntu https://docs.openstack.org/install-guide/environment-etcd-ubuntu.html

echo "Starting installation of Etcd for Ubuntu"

apt install -y etcd

crudini --set /etc/default/etcd "" ETCD_NAME "${CONTROLLER_HOSTNAME}"
crudini --set /etc/default/etcd "" ETCD_DATA_DIR "/var/lib/etcd"
crudini --set /etc/default/etcd "" ETCD_INITIAL_CLUSTER_STATE "new"
crudini --set /etc/default/etcd "" ETCD_INITIAL_CLUSTER_TOKEN "etcd-cluster-01"
crudini --set /etc/default/etcd "" ETCD_INITIAL_CLUSTER "${CONTROLLER_HOSTNAME}=http://${CONTROLLER_IP}:2380"
crudini --set /etc/default/etcd "" ETCD_INITIAL_ADVERTISE_PEER_URLS "http://${CONTROLLER_IP}:2380"
crudini --set /etc/default/etcd "" ETCD_ADVERTISE_CLIENT_URLS "http://${CONTROLLER_IP}:2379"
crudini --set /etc/default/etcd "" ETCD_LISTEN_PEER_URLS "http://0.0.0.0:2380"
crudini --set /etc/default/etcd "" ETCD_LISTEN_CLIENT_URLS "http://${CONTROLLER_IP}:2379"
systemctl enable etcd --now
systemctl start etcd

# from Keystone Install and Configure on Ubuntu https://docs.openstack.org/keystone/pike/install/keystone-install-ubuntu.html

echo "Starting installation of Keystone on Ubuntu"

mysql <<- EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_DBPASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_DBPASS}';
EOF

apt install -y keystone apache2 #libapache2-mod-wsgi
crudini --set /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:${KEYSTONE_DBPASS}@${CONTROLLER_HOSTNAME}/keystone"
crudini --set /etc/keystone/keystone.conf cache enabled true
crudini --set /etc/keystone/keystone.conf cache backend dogpile.cache.memcached
crudini --set /etc/keystone/keystone.conf cache memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/keystone/keystone.conf token provider fernet
crudini --set /etc/keystone/keystone.conf identity default_domain_id default
crudini --set /etc/keystone/keystone.conf identity domain_specific_drivers_enabled True
crudini --set /etc/keystone/keystone.conf identity domain_configurations_from_database True
crudini --set /etc/keystone/keystone.conf domain_config driver sql
su -s /bin/sh -c "keystone-manage db_sync" keystone
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password "${ADMIN_PASS}" --bootstrap-admin-url "http://${CONTROLLER_HOSTNAME}:5000/v3" --bootstrap-internal-url "http://${CONTROLLER_HOSTNAME}:5000/v3" --bootstrap-public-url "http://${CONTROLLER_HOSTNAME}:5000/v3" --bootstrap-region-id RegionOne

cat <<- EOF >> admin-openrc
#! /bin/sh
export OS_USERNAME=admin
export OS_PASSWORD='${ADMIN_PASS}'
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL='http://${CONTROLLER_HOSTNAME}:5000/v3'
export OS_IDENTITY_API_VERSION=3
EOF
chmod 644 admin-openrc

# from Create a domain, projects, users and roles https://docs.openstack.org/keystone/pike/install/keystone-users-ubuntu.html
source admin-openrc
openstack project create --domain default --description "Service Project" service
openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password "${DEMO_PASS}" demo
openstack role create user
openstack role create _member_
openstack role add --domain default --user admin admin
openstack role add --project demo --user demo user

cat <<- EOF >> demo-openrc
#! /bin/sh
export OS_USERNAME=demo
export OS_PASSWORD='${DEMO_PASS}'
export OS_PROJECT_NAME=demo
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL='http://${CONTROLLER_HOSTNAME}:5000/v3'
export OS_IDENTITY_API_VERSION=3
EOF
chmod 644 demo-openrc

# from Install and Configure Glance (Ubuntu) https://docs.openstack.org/glance/pike/install/install-ubuntu.html

echo "Starting installation of Glance on Ubuntu"

mysql <<- EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${GLANCE_DBPASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${GLANCE_DBPASS}';
EOF

source admin-openrc
openstack user create --domain default --password "${GLANCE_PASS}" glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image" image
openstack endpoint create --region RegionOne image public "http://${CONTROLLER_HOSTNAME}:9292"
openstack endpoint create --region RegionOne image internal "http://${CONTROLLER_HOSTNAME}:9292"
openstack endpoint create --region RegionOne image admin "http://${CONTROLLER_HOSTNAME}:9292"

apt install -y glance

crudini --set /etc/glance/glance-api.conf database connection "mysql+pymysql://glance:${GLANCE_DBPASS}@${CONTROLLER_HOSTNAME}/glance"
crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/glance/glance-api.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_type password
crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name default
crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name default
crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name service
crudini --set /etc/glance/glance-api.conf keystone_authtoken username glance
crudini --set /etc/glance/glance-api.conf keystone_authtoken password "${GLANCE_PASS}"
crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone
crudini --set /etc/glance/glance-api.conf glance_store stores "file,http"
crudini --set /etc/glance/glance-api.conf glance_store default_store file
crudini --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/

crudini --set /etc/glance/glance-registry.conf database connection "mysql+pymysql://glance:${GLANCE_DBPASS}@${CONTROLLER_HOSTNAME}/glance"
crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/glance/glance-registry.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/glance/glance-registry.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_type password
crudini --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_name default
crudini --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_name default
crudini --set /etc/glance/glance-registry.conf keystone_authtoken project_name service
crudini --set /etc/glance/glance-registry.conf keystone_authtoken username glance
crudini --set /etc/glance/glance-registry.conf keystone_authtoken password "${GLANCE_PASS}"
crudini --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

su -s /bin/sh -c "glance-manage db_sync" glance

service glance-registry restart
systemctl enable glance-registry --now
service glance-api restart
systemctl enable glance-api --now

# from Verify Operation https://docs.openstack.org/glance/pike/install/verify.html

wget http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img

openstack image create "cirros" --file cirros-0.3.5-x86_64-disk.img --disk-format qcow2 --container-format bare --public

# from Install and configure controller node for Ubuntu https://docs.openstack.org/nova/pike/install/controller-install-ubuntu.html

echo "Starting installation of Nova Controller"

mysql <<- EOF
CREATE DATABASE nova_api;
CREATE DATABASE nova;
CREATE DATABASE nova_cell0;
CREATE DATABASE placement;
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DBPASS}';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DBPASS}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DBPASS}';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DBPASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_DBPASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_DBPASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '${PLACEMENT_DBPASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '${PLACEMENT_DBPASS}';
EOF

source admin-openrc

openstack user create --domain default --password "${NOVA_PASS}" nova
openstack role add --project service --user nova admin
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne compute public "http://${CONTROLLER_HOSTNAME}:8774/v2.1"
openstack endpoint create --region RegionOne compute internal "http://${CONTROLLER_HOSTNAME}:8774/v2.1"
openstack endpoint create --region RegionOne compute admin "http://${CONTROLLER_HOSTNAME}:8774/v2.1"
openstack user create --domain default --password "${PLACEMENT_PASS}" placement
openstack role add --project service --user placement admin
openstack service create --name placement --description "Placement API" placement
openstack endpoint create --region RegionOne placement public "http://${CONTROLLER_HOSTNAME}:8778"
openstack endpoint create --region RegionOne placement internal "http://${CONTROLLER_HOSTNAME}:8778"
openstack endpoint create --region RegionOne placement admin "http://${CONTROLLER_HOSTNAME}:8778"

apt install -y nova-api nova-conductor nova-novncproxy nova-scheduler placement-api

crudini --set /etc/nova/nova.conf api_database connection "mysql+pymysql://nova:${NOVA_DBPASS}@${CONTROLLER_HOSTNAME}/nova_api"
crudini --set /etc/nova/nova.conf database connection "mysql+pymysql://nova:${NOVA_DBPASS}@${CONTROLLER_HOSTNAME}/nova"
crudini --set /etc/nova/nova.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/nova/nova.conf api auth_strategy keystone
crudini --set /etc/nova/nova.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/nova/nova.conf keystone_authtoken auth_type password
crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name default
crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name default
crudini --set /etc/nova/nova.conf keystone_authtoken project_name service
crudini --set /etc/nova/nova.conf keystone_authtoken username nova
crudini --set /etc/nova/nova.conf keystone_authtoken password "${NOVA_PASS}"
crudini --set /etc/nova/nova.conf DEFAULT my_ip "${CONTROLLER_IP}"
crudini --set /etc/nova/nova.conf DEFAULT use_neutron true
crudini --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
crudini --set /etc/nova/nova.conf vnc enabled true
crudini --set /etc/nova/nova.conf vnc vncserver_listen "${CONTROLLER_IP}"
crudini --set /etc/nova/nova.conf vnc vncserver_proxyclient_address "${CONTROLLER_IP}"
crudini --set /etc/nova/nova.conf glance api_servers "http://${CONTROLLER_HOSTNAME}:9292"
crudini --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp
crudini --del /etc/nova/nova.conf DEFAULT log_dir
crudini --set /etc/nova/nova.conf placement os_region_name RegionOne
crudini --set /etc/nova/nova.conf placement region_name RegionOne
crudini --set /etc/nova/nova.conf placement project_domain_name Default
crudini --set /etc/nova/nova.conf placement project_name service
crudini --set /etc/nova/nova.conf placement auth_type password
crudini --set /etc/nova/nova.conf placement user_domain_name Default
crudini --set /etc/nova/nova.conf placement auth_url "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/nova/nova.conf placement username placement
crudini --set /etc/nova/nova.conf placement password "${PLACEMENT_PASS}"

crudini --set /etc/placement/placement.conf placement_database connection "mysql+pymysql://placement:${PLACEMENT_DBPASS}@${CONTROLLER_HOSTNAME}/placement"
crudini --set /etc/placement/placement.conf api auth_strategy keystone
crudini --set /etc/placement/placement.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/placement/placement.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/placement/placement.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/placement/placement.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/placement/placement.conf keystone_authtoken auth_type password
crudini --set /etc/placement/placement.conf keystone_authtoken project_domain_name default
crudini --set /etc/placement/placement.conf keystone_authtoken user_domain_name default
crudini --set /etc/placement/placement.conf keystone_authtoken project_name service
crudini --set /etc/placement/placement.conf keystone_authtoken username placement
crudini --set /etc/placement/placement.conf keystone_authtoken password "${PLACEMENT_PASS}"

su -s /bin/sh -c "nova-manage api_db sync" nova

su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
su -s /bin/sh -c "nova-manage db sync" nova
nova-manage cell_v2 list_cells
su -s /bin/sh -c "placement-manage db sync" placement

for i in api scheduler conductor novncproxy; do service "nova-${i}" restart; done
service apache2 restart

# from Install and configure compute node for Ubuntu https://docs.openstack.org/nova/pike/install/compute-install-ubuntu.html

echo "Starting Installation of Nova Compute"

apt install -y nova-compute

crudini --set /etc/nova/nova.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/nova/nova.conf api auth_strategy keystone
crudini --set /etc/nova/nova.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/nova/nova.conf keystone_authtoken auth_type password
crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name default
crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name default
crudini --set /etc/nova/nova.conf keystone_authtoken project_name service
crudini --set /etc/nova/nova.conf keystone_authtoken username nova
crudini --set /etc/nova/nova.conf keystone_authtoken password "${NOVA_PASS}"
crudini --set /etc/nova/nova.conf DEFAULT my_ip "${CONTROLLER_IP}"
crudini --set /etc/nova/nova.conf DEFAULT use_neutron true
crudini --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
crudini --set /etc/nova/nova.conf vnc enabled true
crudini --set /etc/nova/nova.conf vnc vncserver_listen 0.0.0.0
crudini --set /etc/nova/nova.conf vnc vncserver_proxyclient_address "${CONTROLLER_IP}"
crudini --set /etc/nova/nova.conf vnc novncproxy_base_url "${NOVNCPROXY_BASE_URL}"
crudini --set /etc/nova/nova.conf glance api_servers "http://${CONTROLLER_HOSTNAME}:9292"
crudini --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp
crudini --del /etc/nova/nova.conf DEFAULT log_dir
crudini --set /etc/nova/nova.conf placement os_region_name RegionOne
crudini --set /etc/nova/nova.conf placement region_name RegionOne
crudini --set /etc/nova/nova.conf placement project_domain_name Default
crudini --set /etc/nova/nova.conf placement project_name service
crudini --set /etc/nova/nova.conf placement auth_type password
crudini --set /etc/nova/nova.conf placement user_domain_name Default
crudini --set /etc/nova/nova.conf placement auth_url "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/nova/nova.conf placement username placement
crudini --set /etc/nova/nova.conf placement password "${PLACEMENT_PASS}"

crudini --set /etc/nova/nova-compute.conf libvirt virt_type qemu

service nova-compute restart
systemctl enable nova-compute --now

source admin-openrc
su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova
echo "Executing openstack compute service list"
openstack compute service list
echo "Executing nova-status upgrade check"
nova-status upgrade check
echo "Executing placement-status upgrade check"
placement-status upgrade check

# from Install and configure Neutron controller node https://docs.openstack.org/neutron/pike/install/controller-install-ubuntu.html

echo "Starting installation of Neutron Controller"

mysql <<- EOF
CREATE DATABASE neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_DBPASS}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '${NEUTRON_DBPASS}';
EOF

# Octavia
mysql <<- EOF
CREATE DATABASE octavia;
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'localhost' IDENTIFIED BY '${OCTAVIA_DBPASS}';
GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'%' IDENTIFIED BY '${OCTAVIA_DBPASS}';
EOF
# /Octavia

source admin-openrc

openstack user create --domain default --password "${NEUTRON_PASS}" neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public "http://${CONTROLLER_HOSTNAME}:9696"
openstack endpoint create --region RegionOne network internal "http://${CONTROLLER_HOSTNAME}:9696"
openstack endpoint create --region RegionOne network admin "http://${CONTROLLER_HOSTNAME}:9696"

# Octavia
openstack user create --domain default --password "${OCTAVIA_PASS}" octavia
openstack role add --project service --user octavia admin
openstack service create --name octavia --description "OpenStack Octavia" load-balancer
openstack endpoint create --region RegionOne load-balancer public "http://${CONTROLLER_HOSTNAME}:9876"
openstack endpoint create --region RegionOne load-balancer internal "http://${CONTROLLER_HOSTNAME}:9876"
openstack endpoint create --region RegionOne load-balancer admin "http://${CONTROLLER_HOSTNAME}:9876"
# /Octavia

apt install -y python3-neutron-fwaas octavia-api octavia-health-manager octavia-housekeeping octavia-worker python3-octavia python3-octaviaclient
apt install -y neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent

crudini --set /etc/neutron/neutron.conf database connection "mysql+pymysql://neutron:${NEUTRON_DBPASS}@${CONTROLLER_HOSTNAME}/neutron"
crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins router
#crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins "router,firewall_v2,lbaas"
crudini --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips true
crudini --set /etc/neutron/neutron.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_type password
crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name default
crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name default
crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name service
crudini --set /etc/neutron/neutron.conf keystone_authtoken username neutron
crudini --set /etc/neutron/neutron.conf keystone_authtoken password "${NEUTRON_PASS}"
crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes true
crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes true
crudini --set /etc/neutron/neutron.conf nova auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf nova auth_type password
crudini --set /etc/neutron/neutron.conf nova project_domain_name default
crudini --set /etc/neutron/neutron.conf nova user_domain_name default
crudini --set /etc/neutron/neutron.conf nova region_name RegionOne
crudini --set /etc/neutron/neutron.conf nova project_name service
crudini --set /etc/neutron/neutron.conf nova username nova
crudini --set /etc/neutron/neutron.conf nova password "${NOVA_PASS}"

# workaround for:
# - https://bugs.launchpad.net/openstack-manuals/+bug/1624221
# - https://bugs.launchpad.net/neutron/+bug/1812497
crudini --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lock/neutron

# Octavia # https://docs.openstack.org/octavia/latest/install/install-ubuntu.html
crudini --set /etc/octavia/octavia.conf database connection "mysql+pymysql://octavia:${OCTAVIA_DBPASS}@${CONTROLLER_HOSTNAME}/octavia"
crudini --set /etc/octavia/octavia.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/octavia/octavia.conf oslo_messaging topic octavia_prov
crudini --set /etc/octavia/octavia.conf api_settings bind_host 0.0.0.0
crudini --set /etc/octavia/octavia.conf api_settings bind_port 9876
crudini --set /etc/octavia/octavia.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/octavia/octavia.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/octavia/octavia.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/octavia/octavia.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/octavia/octavia.conf keystone_authtoken auth_type password
crudini --set /etc/octavia/octavia.conf keystone_authtoken project_domain_name default
crudini --set /etc/octavia/octavia.conf keystone_authtoken user_domain_name default
crudini --set /etc/octavia/octavia.conf keystone_authtoken project_name service
crudini --set /etc/octavia/octavia.conf keystone_authtoken username octavia
crudini --set /etc/octavia/octavia.conf keystone_authtoken password "${OCTAVIA_PASS}"
crudini --set /etc/octavia/octavia.conf service_auth auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/octavia/octavia.conf service_auth www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/octavia/octavia.conf service_auth auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/octavia/octavia.conf service_auth memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/octavia/octavia.conf service_auth auth_type password
crudini --set /etc/octavia/octavia.conf service_auth project_domain_name default
crudini --set /etc/octavia/octavia.conf service_auth user_domain_name default
crudini --set /etc/octavia/octavia.conf service_auth project_name service
crudini --set /etc/octavia/octavia.conf service_auth username octavia
crudini --set /etc/octavia/octavia.conf service_auth password "${OCTAVIA_PASS}"
#crudini --set /etc/octavia/octavia.conf certificates server_certs_key_passphrase $(echo insecure-key-do-not-use-this-key | md5sum | awk '{print $1}' | base64 -w0)
#crudini --set /etc/octavia/octavia.conf certificates ca_private_key_passphrase not-secure-passphrase
crudini --set /etc/octavia/octavia.conf certificates ca_private_key /etc/octavia/certs/private/server_ca_key.pem
crudini --set /etc/octavia/octavia.conf certificates ca_certificate /etc/octavia/certs/server_ca.cert.pem
crudini --set /etc/octavia/octavia.conf haproxy_amphora server_ca /etc/octavia/certs/server_ca-chain.cert.pem
crudini --set /etc/octavia/octavia.conf haproxy_amphora client_cert /etc/octavia/certs/private/client.cert-and-key.pem
crudini --set /etc/octavia/octavia.conf health_manager bind_port 5555
crudini --set /etc/octavia/octavia.conf health_manager bind_ip 172.16.0.2  # second ip of octavia mgmt subnet
crudini --set /etc/octavia/octavia.conf health_manager controller_ip_port_list "172.16.0.2:5555"
# /Octavia

## FWAAS
#crudini --set /etc/neutron/neutron.conf service_providers service_provider "FIREWALL_V2:fwaas_db:neutron_fwaas.services.firewall.service_drivers.agents.agents.FirewallAgentDriver:default"
#crudini --set /etc/neutron/neutron_fwaas.conf service_providers service_provider "LOADBALANCER:Haproxy:neutron_lbaas.services.loadbalancer.drivers.haproxy.plugin_driver.HaproxyOnHostPluginDriver:default"
#crudini --set /etc/neutron/neutron.conf service_providers service_provider "LOADBALANCER:Haproxy:neutron_lbaas.services.loadbalancer.drivers.haproxy.plugin_driver.HaproxyOnHostPluginDriver:default"

crudini --set /etc/neutron/neutron_fwaas.conf service_providers service_provider "FIREWALL_V2:fwaas_db:neutron_fwaas.services.firewall.service_drivers.agents.agents.FirewallAgentDriver:default"
crudini --set /etc/neutron/fwaas_driver.ini service_providers service_provider "FIREWALL_V2:fwaas_db:neutron_fwaas.services.firewall.service_drivers.agents.agents.FirewallAgentDriver:default"
crudini --set /etc/neutron/fwaas_driver.ini fwaas enabled True
crudini --set /etc/neutron/fwaas_driver.ini fwaas agent_version v2
crudini --set /etc/neutron/fwaas_driver.ini fwaas driver neutron_fwaas.services.firewall.service_drivers.agents.drivers.linux.iptables_fwaas_v2.IptablesFwaasDriver
crudini --set /etc/neutron/fwaas_driver.ini fwaas firewall_l2_driver noop

#crudini --set /etc/neutron/l3_agent.ini AGENT extensions fwaas_v2
#crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini agent extensions fwaas_v2
#crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini fwaas firewall_l2_driver noop

crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers "flat,vlan,vxlan"
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vxlan
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers "linuxbridge,l2population"
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers port_security
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks provider
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan vni_ranges "1:1000"
crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset true

crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings "provider:${PROVIDER_INTERFACE_NAME}"
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan true
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan local_ip "${OVERLAY_INTERFACE_IP_ADDRESS}"
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan l2_population true
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup enable_security_group true
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup firewall_driver neutron.agent.linux.iptables_firewall.IptablesFirewallDriver

crudini --set /etc/neutron/l3_agent.ini DEFAULT interface_driver linuxbridge

crudini --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver linuxbridge
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata true

crudini --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_host "${CONTROLLER_HOSTNAME}"
crudini --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret "${METADATA_SECRET}"

crudini --set /etc/nova/nova.conf neutron url "http://${CONTROLLER_HOSTNAME}:9696"
crudini --set /etc/nova/nova.conf neutron auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf neutron auth_type password
crudini --set /etc/nova/nova.conf neutron project_domain_name default
crudini --set /etc/nova/nova.conf neutron user_domain_name default
crudini --set /etc/nova/nova.conf neutron region_name RegionOne
crudini --set /etc/nova/nova.conf neutron project_name service
crudini --set /etc/nova/nova.conf neutron username neutron
crudini --set /etc/nova/nova.conf neutron password "${NEUTRON_PASS}"
crudini --set /etc/nova/nova.conf neutron service_metadata_proxy true
crudini --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret "${METADATA_SECRET}"

su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
su -s /bin/sh -c "neutron-db-manage --subproject neutron-fwaas --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
su -s /bin/sh -c "neutron-db-manage --config-file /etc/octavia/octavia.conf upgrade head" octavia

service nova-api restart
systemctl enable nova-api --now
service neutron-server restart
systemctl enable neutron-server --now
for i in linuxbridge dhcp metadata l3; do
  service "neutron-${i}-agent" restart
  systemctl enable "neutron-${i}-agent" --now
done
for i in api health-manager housekeeping worker; do
  service "octavia-${i}" restart
  systemctl enable "octavia-${i}" --now
done

# from Install and configure (Neutron) compute node https://docs.openstack.org/neutron/pike/install/compute-install-ubuntu.html

echo "Starting installation of Neutron Compute Node"

apt install -y neutron-linuxbridge-agent

crudini --set /etc/neutron/neutron.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_type password
crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name default
crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name default
crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name service
crudini --set /etc/neutron/neutron.conf keystone_authtoken username neutron
crudini --set /etc/neutron/neutron.conf keystone_authtoken password "${NEUTRON_PASS}"

crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings "provider:${PROVIDER_INTERFACE_NAME}"
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan true
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan local_ip "${OVERLAY_INTERFACE_IP_ADDRESS}"
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan l2_population true
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup enable_security_group true
crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup firewall_driver neutron.agent.linux.iptables_firewall.IptablesFirewallDriver

crudini --set /etc/nova/nova.conf neutron url "http://${CONTROLLER_HOSTNAME}:9696"
crudini --set /etc/nova/nova.conf neutron auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/nova/nova.conf neutron auth_type password
crudini --set /etc/nova/nova.conf neutron project_domain_name default
crudini --set /etc/nova/nova.conf neutron user_domain_name default
crudini --set /etc/nova/nova.conf neutron region_name RegionOne
crudini --set /etc/nova/nova.conf neutron project_name service
crudini --set /etc/nova/nova.conf neutron username neutron
crudini --set /etc/nova/nova.conf neutron password "${NEUTRON_PASS}"

service nova-compute restart
systemctl enable nova-compute --now
service neutron-linuxbridge-agent restart
systemctl enable neutron-linuxbridge-agent --now

echo "Executing openstack network agent list"
source admin-openrc
openstack network agent list

# from Swift - Install and configure controller node for Ubuntu https://docs.openstack.org/swift/pike/install/controller-install-ubuntu.html

echo "Starting Swift Controller installation"

source admin-openrc
openstack user create --domain default --password "${SWIFT_PASS}" swift
openstack role add --project service --user swift admin
openstack service create --name swift --description "OpenStack Object Storage" object-store
openstack endpoint create --region RegionOne object-store public "http://${CONTROLLER_HOSTNAME}:8080/v1/AUTH_%(project_id)s"
openstack endpoint create --region RegionOne object-store internal "http://${CONTROLLER_HOSTNAME}:8080/v1/AUTH_%(project_id)s"
openstack endpoint create --region RegionOne object-store admin "http://${CONTROLLER_HOSTNAME}:8080/v1"

apt install -y swift swift-proxy python3-swiftclient python3-keystoneclient python3-keystonemiddleware memcached
[ "$(lsb_release -cs)" = "focal" ] || apt install -y python-swiftclient python-keystoneclient python-keystonemiddleware

mkdir -p /etc/swift
cp /usr/share/doc/swift-proxy/proxy-server.conf-sample /etc/swift/proxy-server.conf

crudini --set /etc/swift/proxy-server.conf DEFAULT bind_port 8080
crudini --set /etc/swift/proxy-server.conf DEFAULT user swift
crudini --set /etc/swift/proxy-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline "catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server"
crudini --set /etc/swift/proxy-server.conf app:proxy-server use "egg:swift#proxy"
crudini --set /etc/swift/proxy-server.conf app:proxy-server account_autocreate true
crudini --set /etc/swift/proxy-server.conf filter:keystoneauth use "egg:swift#keystoneauth"
crudini --set /etc/swift/proxy-server.conf filter:keystoneauth operator_roles "admin,user"
crudini --set /etc/swift/proxy-server.conf filter:authtoken paste.filter_factory "keystonemiddleware.auth_token:filter_factory"
crudini --set /etc/swift/proxy-server.conf filter:authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/swift/proxy-server.conf filter:authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/swift/proxy-server.conf filter:authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/swift/proxy-server.conf filter:authtoken auth_type password
crudini --set /etc/swift/proxy-server.conf filter:authtoken project_domain_id default
crudini --set /etc/swift/proxy-server.conf filter:authtoken user_domain_id default
crudini --set /etc/swift/proxy-server.conf filter:authtoken project_name service
crudini --set /etc/swift/proxy-server.conf filter:authtoken username swift
crudini --set /etc/swift/proxy-server.conf filter:authtoken password "${SWIFT_PASS}"
crudini --set /etc/swift/proxy-server.conf filter:authtoken delay_auth_decision True
crudini --set /etc/swift/proxy-server.conf filter:cache use "egg:swift#memcache"
crudini --set /etc/swift/proxy-server.conf filter:cache memcache_servers "${CONTROLLER_HOSTNAME}:11211"

# from Swift Install and configure the storage node for Ubuntu https://docs.openstack.org/swift/pike/install/storage-install-ubuntu-debian.html

echo "Starting Swift Install Storage Node"

apt install -y xfsprogs rsync

for i in "${SWIFT_DEV_1_1}" "${SWIFT_DEV_1_2}" "${SWIFT_DEV_2_1}" "${SWIFT_DEV_2_2}"; do
  mkfs.xfs "/dev/${OS_DATA_VG}/${i}"
  mkdir -p "/srv/node/${i}"
  echo "/dev/${OS_DATA_VG}/${i} /srv/node/${i} xfs noatime,nodiratime,logbufs=8 0 2" >> /etc/fstab
  mount "/srv/node/${i}"
done

cat <<- EOF > /etc/rsyncd.conf
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = ${CONTROLLER_IP}

[account]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/account.lock

[container]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/container.lock

[object]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/object.lock
EOF

crudini --set /etc/default/rsync "" RSYNC_ENABLE true
service rsync start
systemctl enable rsync --now

apt install -y swift swift-account swift-container swift-object

for i in account container object; do  #container-reconciler internal-client
  cp "/usr/share/doc/swift-${i}/${i}-server.conf-sample" "/etc/swift/${i}-server.conf"
done
curl -o "/etc/swift/internal-client.conf" "https://opendev.org/openstack/swift/raw/branch/stable/${OS_RELEASE}/etc/internal-client.conf-sample"

crudini --set /etc/swift/account-server.conf DEFAULT bind_ip "${CONTROLLER_IP}"
crudini --set /etc/swift/account-server.conf DEFAULT bind_port 6202
crudini --set /etc/swift/account-server.conf DEFAULT user swift
crudini --set /etc/swift/account-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/account-server.conf DEFAULT devices /srv/node
crudini --set /etc/swift/account-server.conf DEFAULT mount_check True
crudini --set /etc/swift/account-server.conf pipeline:main pipeline "healthcheck recon account-server"
crudini --set /etc/swift/account-server.conf filter:recon use "egg:swift#recon"
crudini --set /etc/swift/account-server.conf filter:recon recon_cache_path /var/cache/swift
crudini --set /etc/swift/container-server.conf DEFAULT bind_ip "${CONTROLLER_IP}"
crudini --set /etc/swift/container-server.conf DEFAULT bind_port 6201
crudini --set /etc/swift/container-server.conf DEFAULT user swift
crudini --set /etc/swift/container-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/container-server.conf DEFAULT devices /srv/node
crudini --set /etc/swift/container-server.conf DEFAULT mount_check True
crudini --set /etc/swift/container-server.conf pipeline:main pipeline "healthcheck recon container-server"
crudini --set /etc/swift/container-server.conf filter:recon use "egg:swift#recon"
crudini --set /etc/swift/container-server.conf filter:recon recon_cache_path /var/cache/swift
crudini --set /etc/swift/object-server.conf DEFAULT bind_ip "${CONTROLLER_IP}"
crudini --set /etc/swift/object-server.conf DEFAULT bind_port 6200
crudini --set /etc/swift/object-server.conf DEFAULT user swift
crudini --set /etc/swift/object-server.conf DEFAULT swift_dir /etc/swift
crudini --set /etc/swift/object-server.conf DEFAULT devices /srv/node
crudini --set /etc/swift/object-server.conf DEFAULT mount_check true
crudini --set /etc/swift/object-server.conf pipeline:main pipeline "healthcheck recon object-server"
crudini --set /etc/swift/object-server.conf filter:recon use "egg:swift#recon"
crudini --set /etc/swift/object-server.conf filter:recon recon_cache_path /var/cache/swift
crudini --set /etc/swift/object-server.conf filter:recon recon_lock_path /var/lock

for i in account container object; do crudini --set "/etc/swift/${i}-server.conf" filter:healthcheck use "egg:swift#healthcheck"; done
for i in healthcheck catch_errors gatekeeper proxy-logging container_sync bulk ratelimit container-quotas account-quotas slo dlo versioned_writes; do crudini --set /etc/swift/proxy-server.conf "filter:${i}" use "egg:swift#${i//-/_}"; done

chown -R swift:swift /srv/node
mkdir -p /var/cache/swift
chown -R root:swift /var/cache/swift
chmod -R 775 /var/cache/swift

# from Create and distribute initial rings https://docs.openstack.org/swift/pike/install/initial-rings.html

echo "Starting Create and distribute initial rings"
cd /etc/swift
swift-ring-builder account.builder create 8 1 1 # 2^8 partitions, 1 replica and 1 hour
swift-ring-builder account.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6202 --device "${SWIFT_DEV_1_1}" --weight 100
swift-ring-builder account.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6202 --device "${SWIFT_DEV_1_2}" --weight 100
echo "Executing swift-ring-builder account.builder"
swift-ring-builder account.builder
echo "Executing swift-ring-builder account.builder rebalance"
swift-ring-builder account.builder rebalance

swift-ring-builder container.builder create 8 1 1 # 2^8 partitions, 1 replica and 1 hour
swift-ring-builder container.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6201 --device "${SWIFT_DEV_1_1}" --weight 100
swift-ring-builder container.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6201 --device "${SWIFT_DEV_1_2}" --weight 100
echo "Executing swift-ring-builder container.builder"
swift-ring-builder container.builder
echo "Executing swift-ring-builder container.builder rebalance"
swift-ring-builder container.builder rebalance

swift-ring-builder object.builder create 8 1 1 # 2^8 partitions, 1 replica and 1 hour
swift-ring-builder object.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6200 --device "${SWIFT_DEV_1_1}" --weight 100
swift-ring-builder object.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6200 --device "${SWIFT_DEV_1_2}" --weight 100
echo "Executing swift-ring-builder object.builder"
swift-ring-builder object.builder
echo "Executing swift-ring-builder object.builder rebalance"
swift-ring-builder object.builder rebalance

# from Swift Finalize installation for Ubuntu https://docs.openstack.org/swift/pike/install/finalize-installation-ubuntu-debian.html

echo "Finalizing Swift installation"
cp /usr/share/doc/swift/swift.conf-sample /etc/swift/swift.conf
crudini --set /etc/swift/swift.conf swift-hash swift_hash_path_prefix Open
crudini --set /etc/swift/swift.conf swift-hash swift_hash_path_suffix Stack
crudini --set /etc/swift/swift.conf storage-policy:0 name Policy-0
crudini --set /etc/swift/swift.conf storage-policy:0 aliases "yellow, orange"
crudini --set /etc/swift/swift.conf storage-policy:0 default yes

chown -R root:swift /etc/swift
service memcached restart
[ "$(lsb_release -cs)" = "focal" ] || service swift-proxy restart
swift-init all restart

# Create second Swift policy for Course exercises, from https://docs.openstack.org/swift/pike/overview_policies.html

echo "Starting to create second Swift Policy"
crudini --set /etc/swift/swift.conf storage-policy:1 name silver
cd /etc/swift
swift-ring-builder object-1.builder create 8 1 1 # 2^8 partitions, 1 replica and 1 hour
swift-ring-builder object-1.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6200 --device "${SWIFT_DEV_2_1}" --weight 100
swift-ring-builder object-1.builder add --region 1 --zone 1 --ip "${CONTROLLER_IP}" --port 6200 --device "${SWIFT_DEV_2_2}" --weight 100
echo "Executing swift-ring-builder object-1.builder"
swift-ring-builder object-1.builder
echo "Executing swift-ring-builder object-1.builder rebalance"
swift-ring-builder object-1.builder rebalance

# from Cinder Install and configure a storage node https://docs.openstack.org/cinder/pike/install/cinder-storage-install-ubuntu.html

echo "Starting installation of Cinder Storage Node"
apt install -y lvm2 thin-provisioning-tools

# Edit /etc/lvm/lvm.conf to include:
# filter = [ "a|dm-4|", "a|dm-5|", "r|.*|"
cat <<- EOF > "${HOME_DIR}/script.sed"
/devices {/a \        filter = [ "a|/dev/${OS_DATA_VG}/${CINDER_VOL1}|", "a|/dev/${OS_DATA_VG}/${CINDER_VOL2}|", "r|.*|" ]
EOF

# allow for nested LVs for Cinder pools
sed -i -f "${HOME_DIR}/script.sed" -e 's/scan_lvs = [0-9]/scan_lvs = 1/' /etc/lvm/lvm.conf

pvcreate "/dev/${OS_DATA_VG}/${CINDER_VOL1}"
vgcreate cinder-volumes "/dev/${OS_DATA_VG}/${CINDER_VOL1}"
pvcreate "/dev/${OS_DATA_VG}/${CINDER_VOL2}"
vgcreate cinder-volumes-2 "/dev/${OS_DATA_VG}/${CINDER_VOL2}"

apt install -y cinder-volume tgt
echo 'include /var/lib/cinder/volumes/*' >> /etc/tgt/targets.conf  # fixes cinder↔tgt mounting

crudini --set /etc/cinder/cinder.conf database connection "mysql+pymysql://cinder:${CINDER_DBPASS}@${CONTROLLER_HOSTNAME}/cinder"
crudini --set /etc/cinder/cinder.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
crudini --set /etc/cinder/cinder.conf DEFAULT my_ip "${CONTROLLER_IP}"
crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends "lvm, lvm-2"
crudini --set /etc/cinder/cinder.conf DEFAULT glance_api_servers "http://${CONTROLLER_HOSTNAME}:9292"
crudini --set /etc/cinder/cinder.conf oslo_concurrency lock_path /var/lib/cinder/tmp
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/cinder/cinder.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_type password
crudini --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name default
crudini --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name default
crudini --set /etc/cinder/cinder.conf keystone_authtoken project_name service
crudini --set /etc/cinder/cinder.conf keystone_authtoken username cinder
crudini --set /etc/cinder/cinder.conf keystone_authtoken password "${CINDER_PASS}"
crudini --set /etc/cinder/cinder.conf lvm volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
crudini --set /etc/cinder/cinder.conf lvm volume_group cinder-volumes
crudini --set /etc/cinder/cinder.conf lvm iscsi_protocol iscsi
crudini --set /etc/cinder/cinder.conf lvm iscsi_helper tgtadm
# setting directly below not in Cinder Installation Guide, but required for COA Lab
crudini --set /etc/cinder/cinder.conf lvm volume_backend_name LVM
crudini --set /etc/cinder/cinder.conf lvm-2 volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
crudini --set /etc/cinder/cinder.conf lvm-2 volume_group cinder-volumes-2
crudini --set /etc/cinder/cinder.conf lvm-2 iscsi_protocol iscsi
crudini --set /etc/cinder/cinder.conf lvm-2 iscsi_helper tgtadm
crudini --set /etc/cinder/cinder.conf lvm-2 volume_backend_name LVM-2
service tgt restart
systemctl enable tgt --now
service cinder-volume restart
systemctl enable cinder-volume --now

# from Cinder Install and configure controller node https://docs.openstack.org/cinder/pike/install/cinder-controller-install-ubuntu.html

echo "Starting installation of Cinder Controller Node"
mysql <<- EOF
CREATE DATABASE cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '${CINDER_DBPASS}';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '${CINDER_DBPASS}';
EOF

cd "${HOME_DIR}"
source admin-openrc
openstack user create --domain default --password "${CINDER_PASS}" cinder
openstack role add --project service --user cinder admin
openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3
openstack endpoint create --region RegionOne volumev2 public "http://${CONTROLLER_HOSTNAME}:8776/v2/%(project_id)s"
openstack endpoint create --region RegionOne volumev2 internal "http://${CONTROLLER_HOSTNAME}:8776/v2/%(project_id)s"
openstack endpoint create --region RegionOne volumev2 admin "http://${CONTROLLER_HOSTNAME}:8776/v2/%(project_id)s"
openstack endpoint create --region RegionOne volumev3 public "http://${CONTROLLER_HOSTNAME}:8776/v3/%(project_id)s"
openstack endpoint create --region RegionOne volumev3 internal "http://${CONTROLLER_HOSTNAME}:8776/v3/%(project_id)s"
openstack endpoint create --region RegionOne volumev3 admin "http://${CONTROLLER_HOSTNAME}:8776/v3/%(project_id)s"

apt install -y cinder-api cinder-scheduler

crudini --set /etc/cinder/cinder.conf database connection "mysql+pymysql://cinder:${CINDER_DBPASS}@${CONTROLLER_HOSTNAME}/cinder"
crudini --set /etc/cinder/cinder.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
crudini --set /etc/cinder/cinder.conf DEFAULT my_ip "${CONTROLLER_IP}"
crudini --set /etc/cinder/cinder.conf DEFAULT enabled_backends "lvm,lvm-2"
crudini --set /etc/cinder/cinder.conf DEFAULT glance_api_servers "http://${CONTROLLER_HOSTNAME}:9292"
crudini --set /etc/cinder/cinder.conf oslo_concurrency lock_path /var/lib/cinder/tmp
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/cinder/cinder.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/cinder/cinder.conf keystone_authtoken auth_type password
crudini --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name default
crudini --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name default
crudini --set /etc/cinder/cinder.conf keystone_authtoken project_name service
crudini --set /etc/cinder/cinder.conf keystone_authtoken username cinder
crudini --set /etc/cinder/cinder.conf keystone_authtoken password "${CINDER_PASS}"

su -s /bin/sh -c "cinder-manage db sync" cinder

crudini --set /etc/nova/nova.conf cinder os_region_name RegionOne

service nova-api restart
systemctl enable nova-api --now
service cinder-scheduler restart
systemctl enable cinder-scheduler --now
service apache2 restart

# from Cinder Install and configure the backup service https://docs.openstack.org/cinder/pike/install/cinder-backup-install-ubuntu.html

echo "Starting installation of Cinder Backup Service"
apt install -y cinder-backup
crudini --set /etc/cinder/cinder.conf DEFAULT backup_driver cinder.backup.drivers.swift.SwiftBackupDriver
crudini --set /etc/cinder/cinder.conf DEFAULT backup_swift_url "http://${CONTROLLER_HOSTNAME}:8080/v1/AUTH_"

service cinder-backup restart
systemctl enable cinder-backup --now
service cinder-volume restart
systemctl enable cinder-volume --now

# from Heat Install and configure for Ubuntu https://docs.openstack.org/heat/pike/install/install-ubuntu.html

echo "Starting Heat Install and Configure"
mysql <<- EOF
CREATE DATABASE heat;
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '${HEAT_DBPASS}';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '${HEAT_DBPASS}';
EOF
cd "${HOME_DIR}"
source admin-openrc
openstack user create --domain default --password "${HEAT_PASS}" heat
openstack role add --project service --user heat admin
openstack service create --name heat --description "Orchestration" orchestration
openstack service create --name heat-cfn --description "Orchestration"  cloudformation
openstack endpoint create --region RegionOne orchestration public "http://${CONTROLLER_HOSTNAME}:8004/v1/%(tenant_id)s"
openstack endpoint create --region RegionOne orchestration internal "http://${CONTROLLER_HOSTNAME}:8004/v1/%(tenant_id)s"
openstack endpoint create --region RegionOne orchestration admin "http://${CONTROLLER_HOSTNAME}:8004/v1/%(tenant_id)s"
openstack endpoint create --region RegionOne cloudformation public "http://${CONTROLLER_HOSTNAME}:8000/v1"
openstack endpoint create --region RegionOne cloudformation internal "http://${CONTROLLER_HOSTNAME}:8000/v1"
openstack endpoint create --region RegionOne cloudformation admin "http://${CONTROLLER_HOSTNAME}:8000/v1"
openstack domain create --description "Stack projects and users" heat
openstack user create --domain heat --password "${HEAT_PASS}" heat_domain_admin
openstack role add --domain heat --user-domain heat --user heat_domain_admin admin
openstack role create heat_stack_owner
openstack role add --project demo --user demo heat_stack_owner
openstack role create heat_stack_user
apt install -y heat-api heat-api-cfn heat-engine
[ "$(lsb_release -cs)" != "focal" ] || apt install -y python3-vitrageclient python3-zunclient
crudini --set /etc/heat/heat.conf database connection "mysql+pymysql://heat:${HEAT_DBPASS}@${CONTROLLER_HOSTNAME}/heat"
crudini --set /etc/heat/heat.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/heat/heat.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/heat/heat.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/heat/heat.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/heat/heat.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/heat/heat.conf keystone_authtoken auth_type password
crudini --set /etc/heat/heat.conf keystone_authtoken project_domain_name default
crudini --set /etc/heat/heat.conf keystone_authtoken user_domain_name default
crudini --set /etc/heat/heat.conf keystone_authtoken project_name service
crudini --set /etc/heat/heat.conf keystone_authtoken username heat
crudini --set /etc/heat/heat.conf keystone_authtoken password "${HEAT_PASS}"
crudini --set /etc/heat/heat.conf trustee auth_type password
crudini --set /etc/heat/heat.conf trustee auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/heat/heat.conf trustee username heat
crudini --set /etc/heat/heat.conf trustee password "${HEAT_PASS}"
crudini --set /etc/heat/heat.conf trustee user_domain_name default
crudini --set /etc/heat/heat.conf clients_keystone auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/heat/heat.conf ec2authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/heat/heat.conf DEFAULT heat_metadata_server_url "http://${CONTROLLER_HOSTNAME}:8000"
crudini --set /etc/heat/heat.conf DEFAULT heat_waitcondition_server_url "http://${CONTROLLER_HOSTNAME}:8000/v1/waitcondition"
crudini --set /etc/heat/heat.conf DEFAULT stack_domain_admin heat_domain_admin
crudini --set /etc/heat/heat.conf DEFAULT stack_domain_admin_password "${HEAT_PASS}"
crudini --set /etc/heat/heat.conf DEFAULT stack_user_domain_name heat
su -s /bin/sh -c "heat-manage db_sync" heat
service heat-api restart
systemctl enable heat-api --now
service heat-api-cfn restart
systemctl enable heat-api-cfn --now
service heat-engine restart
systemctl enable heat-engine --now

# from Barbican Install for Ubuntu https://docs.openstack.org/barbican/pike/install/install-ubuntu.html

echo "Starting Barbican Installation"
mysql <<- EOF
CREATE DATABASE barbican;
GRANT ALL PRIVILEGES ON barbican.* TO 'barbican'@'localhost' IDENTIFIED BY '${BARBICAN_DBPASS}';
GRANT ALL PRIVILEGES ON barbican.* TO 'barbican'@'%' IDENTIFIED BY '${BARBICAN_DBPASS}';
EOF
cd "${HOME_DIR}"
source admin-openrc
openstack user create --domain default --password "${BARBICAN_PASS}" barbican
openstack role add --project service --user barbican admin
openstack role create creator
openstack role add --project service --user barbican creator
openstack service create --name barbican --description "Key Manager" key-manager
openstack endpoint create --region RegionOne key-manager public "http://${CONTROLLER_HOSTNAME}:9311"
openstack endpoint create --region RegionOne key-manager internal "http://${CONTROLLER_HOSTNAME}:9311"
openstack endpoint create --region RegionOne key-manager admin "http://${CONTROLLER_HOSTNAME}:9311"
apt install -y barbican-api barbican-keystone-listener barbican-worker
crudini --set /etc/barbican/barbican.conf DEFAULT sql_connection "mysql+pymysql://barbican:${BARBICAN_DBPASS}@${CONTROLLER_HOSTNAME}/barbican"
crudini --set /etc/barbican/barbican.conf DEFAULT transport_url "rabbit://openstack:${RABBIT_PASS}@${CONTROLLER_HOSTNAME}"
crudini --set /etc/barbican/barbican.conf DEFAULT db_auto_create False
crudini --set /etc/barbican/barbican.conf keystone_authtoken auth_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/barbican/barbican.conf keystone_authtoken www_authenticate_uri "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/barbican/barbican.conf keystone_authtoken auth_url "http://${CONTROLLER_HOSTNAME}:5000"
crudini --set /etc/barbican/barbican.conf keystone_authtoken memcached_servers "${CONTROLLER_HOSTNAME}:11211"
crudini --set /etc/barbican/barbican.conf keystone_authtoken auth_type password
crudini --set /etc/barbican/barbican.conf keystone_authtoken project_domain_name default
crudini --set /etc/barbican/barbican.conf keystone_authtoken user_domain_name default
crudini --set /etc/barbican/barbican.conf keystone_authtoken project_name service
crudini --set /etc/barbican/barbican.conf keystone_authtoken username barbican
crudini --set /etc/barbican/barbican.conf keystone_authtoken password "${BARBICAN_PASS}"
su -s /bin/sh -c "barbican-manage db upgrade" barbican

# from Barbican Secret Store Back-ends https://docs.openstack.org/barbican/pike/install/barbican-backend.html#barbican-backend
crudini --set /etc/barbican/barbican.conf secretstore namespace barbican.secretstore.plugin
crudini --set /etc/barbican/barbican.conf secretstore enabled_secretstore_plugins store_crypto
crudini --set /etc/barbican/barbican.conf crypto enabled_crypto_plugins simple_crypto
crudini --set /etc/barbican/barbican.conf simple_crypto_plugin kek "'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY='"
service barbican-keystone-listener restart
systemctl enable barbican-keystone-listener --now
service barbican-worker restart
systemctl enable barbican-worker --now
service apache2 restart

# from Cinder Volume encryption supported by the key manager https://docs.openstack.org/cinder/pike/configuration/block-storage/volume-encryption.html
crudini --set /etc/nova/nova.conf key_manager backend barbican
crudini --set /etc/nova/nova.conf barbican barbican_endpoint "http://${CONTROLLER_HOSTNAME}:9311/"
crudini --set /etc/nova/nova.conf barbican auth_endpoint "http://${CONTROLLER_HOSTNAME}:5000/v3"
crudini --set /etc/cinder/cinder.conf key_manager backend barbican
crudini --set /etc/cinder/cinder.conf barbican barbican_endpoint "http://${CONTROLLER_HOSTNAME}:9311/"
crudini --set /etc/cinder/cinder.conf barbican auth_endpoint "http://${CONTROLLER_HOSTNAME}:5000/v3"
openstack role add --project demo --user demo creator
service cinder-scheduler restart
systemctl enable cinder-scheduler --now
service nova-compute restart
systemctl enable nova-compute --now
service apache2 restart

# from Horizon Install and configure for Ubuntu https://docs.openstack.org/horizon/pike/install/install-ubuntu.html

echo "Starting Horizon Installation"
apt install -y openstack-dashboard
[ "$(lsb_release -cs)" != "bionic" ] || apt install -y python-neutron-fwaas-dashboard
apt install -y python3-heat-dashboard python3-neutron-fwaas-dashboard python3-octavia-dashboard
# Horizon is accessed from Host system via http://localhost:8080/horizon/, so we keep OPENSTACK_HOSTS="127.0.0.1" - this is the reason of not executing line below
#sed -i "s/127.0.0.1/${CONTROLLER_IP}/g" /etc/openstack-dashboard/local_settings.py
#sed -i "/^OPENSTACK_KEYSTONE_URL/s/v2.0/v3/" /etc/openstack-dashboard/local_settings.py
sed -i 's;^#\?OPENSTACK_KEYSTONE_URL[[:space:]]*=.*;OPENSTACK_KEYSTONE_URL = "http://%s:5000/identity/v3" % OPENSTACK_HOST;g' /etc/openstack-dashboard/local_settings.py
sed -i "/^CACHES =/i SESSION_ENGINE = 'django.contrib.sessions.backends.cache'" /etc/openstack-dashboard/local_settings.py
sed -i "s/127.0.0.1:11211/${CONTROLLER_IP}:11211/g" /etc/openstack-dashboard/local_settings.py
sed -i '/^#OPENSTACK_API_VERSIONS =/i OPENSTACK_API_VERSIONS = { "identity": 3 ,"image": 2 ,"volume": 2, }' /etc/openstack-dashboard/local_settings.py
cat <<EOF >> /etc/openstack-dashboard/local_settings.py

OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = "Default"
EOF
sed -i "s/_member_/user/" /etc/openstack-dashboard/local_settings.py
# Extra, undocumented line to enable Volume Backup option in Horizon
sed -i "s/'enable_backup': False/'enable_backup': True/" /etc/openstack-dashboard/local_settings.py
# Let's change Horizon theme from Ubuntu to default
sed -i "/^DEFAULT_THEME/s/ubuntu/default/" /etc/openstack-dashboard/local_settings.py
grep -q 'WSGIApplicationGroup %{GLOBAL}' /etc/apache2/conf-available/openstack-dashboard.conf || sed -i '/^WSGIProcessGroup/a WSGIApplicationGroup %{GLOBAL}' /etc/apache2/conf-available/openstack-dashboard.conf
service apache2 restart

apt -y autoremove
apt clean

# For good measure
su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova
for i in backup volume; do service "cinder-${i}" restart; done
for i in conductor scheduler; do service "nova-${i}" restart; done
