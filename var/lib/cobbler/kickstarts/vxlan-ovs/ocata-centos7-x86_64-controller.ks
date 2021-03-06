# kickstart template for Fedora 8 and later.
# (includes %end blocks)
# do not use with earlier distros

#platform=x86, AMD64, or Intel EM64T
# System authorization information
auth  --useshadow  --enablemd5
# System bootloader configuration
bootloader --location=mbr
# Partition clearing information
clearpart --all --initlabel
# Use text mode install
text
# Firewall configuration
firewall --disable
# Run the Setup Agent on first boot
firstboot --disable
# System keyboard
keyboard us
# System language
lang en_US
# Use network installation
url --url=$tree
# If any cobbler repo definitions were referenced in the kickstart profile, include them here.
$yum_repo_stanza
# Network information
$SNIPPET('network_config')
# Reboot after installation
reboot

#Root password
rootpw --iscrypted $default_password_crypted
# SELinux configuration
selinux --disabled
# Do not configure the X Window System
skipx
# System timezone
timezone Asia/Shanghai
# Install OS instead of upgrade
install
# Clear the Master Boot Record
zerombr
# Allow anaconda to partition the system as needed
autopart

%pre
$SNIPPET('log_ks_pre')
$SNIPPET('kickstart_start')
$SNIPPET('pre_install_network_config')
# Enable installation monitoring
$SNIPPET('pre_anamon')
%end

%packages
$SNIPPET('func_install_if_enabled')
%end

%post --nochroot
$SNIPPET('log_ks_post_nochroot')
%end

%post
$SNIPPET('log_ks_post')
# Start yum configuration
$yum_config_stanza
# Enable lan centos source
mkdir /etc/yum.repos.d/.bakup
mv /etc/yum.repos.d/CentOS-* /etc/yum.repos.d/.bakup/
cat <<'EOF' > /etc/yum.repos.d/Centos-7-lan.repo
[centos7]
name=CentOS-$releasever - Media
baseurl=http://192.161.14.180/CENTOS7/dvd/centos
gpgcheck=0
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[epel7]
name=CentOS-$releasever - Media
baseurl=http://192.161.14.24/mirrors/epel/7/x86_64
gpgcheck=0
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF
yum clean all
# End yum configuration
$SNIPPET('post_install_kernel_options')
$SNIPPET('post_install_network_config')
$SNIPPET('func_register_if_enabled')
$SNIPPET('download_config_files')
$SNIPPET('koan_environment')
$SNIPPET('redhat_register')
$SNIPPET('cobbler_register')
# Enable post-install boot notification
$SNIPPET('post_anamon')
# prepare for openstack installation
cat <<'EOF' >> /etc/hosts
10.0.0.51 controller1 controller1.local
10.0.0.55 compute1 compute1.local
10.0.0.56 compute2 compute2.local
10.0.0.59 network1 network1.local
10.0.0.60 cinder1 cinder1.local
10.0.0.61 nfs1 nfs1.local
10.0.0.62 object1 object1.local
10.0.0.63 object2 object2.local
EOF
systemctl disable firewalld
systemctl stop firewalld
systemctl disable NetworkManager
systemctl stop NetworkManager
systemctl enable network
systemctl start network
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
setenforce 0
# ntp config
yum install -y ntp
sed -i 's/#restrict 192.168.1.0 mask 255.255.255.0 nomodify notrap/restrict 10.0.0.0 mask 255.255.255.0 nomodify no trap/g' /etc/ntp.conf
sed -i 's/\.centos\.pool\.ntp\.org/\.cn\.pool\.ntp\.org/g' /etc/ntp.conf
sed -i '25i\server  127.127.1.0     # local clock' /etc/ntp.conf
sed -i '26i\fudge   127.127.1.0 stratum 10' /etc/ntp.conf

systemctl enable ntpd.service
systemctl start ntpd.service
ntpq -p
####################################################################################################
#
#       安装packstack
#
####################################################################################################
yum update -y
yum install -y wget crudini net-tools vim ntpdate bash-completion
yum install -y openstack-packstack openstack-selinux
####################################################################################################
#
#       搭建Mariadb
#
####################################################################################################
# database install
yum install -y mariadb-server mariadb-client python2-PyMySQL
cat <<'EOF' > /etc/my.cnf.d/openstack.cnf
[mysqld]
bind-address = 10.0.0.51
default-storage-engine = innodb
innodb_file_per_table
collation-server = utf8_general_ci
init-connect = 'SET NAMES utf8'
character-set-server = utf8
EOF
systemctl enable mariadb.service
systemctl start mariadb.service
systemctl status mariadb.service
systemctl list-unit-files |grep mariadb.service
# 给mariadb设置密码,先按回车，然后按Y，设置mysql密码，然后一直按y结束
# (root/123456)
mysql_secure_installation
# MQ install(user:openstack/123456)

# mysql数据库最大连接数调整  
# 1.查看mariadb数据库最大连接数，默认为151  
mysql -uroot -p123456 <<'EOF'
show variables like 'max_connections';
EOF
# 2.配置/etc/my.cnf 
#[mysqld]新添加一行如下参数：  
# max_connections=1000
sed -i '13i\max_connections=1000' /etc/my.cnf

#重启mariadb服务，再次查看mariadb数据库最大连接数，可以看到最大连接数是214，并非我们设置的1000。(由于mariadb有默认打开文件数限制)  
systemctl restart mariadb.service
mysql -uroot -p123456 <<'EOF'
show variables like 'max_connections';
EOF
# 3.配置/usr/lib/systemd/system/mariadb.service
# [Service]新添加两行如下参数：
sed -i '/^\[Service\]/a\LimitNOFILE=10000\nLimitNPROC=10000' /usr/lib/systemd/system/mariadb.service

# 4.重新加载系统服务，并重启mariadb服务  
systemctl --system daemon-reload  
systemctl restart mariadb.service 
mysql -uroot -p123456 <<'EOF'
show variables like 'max_connections';
EOF

####################################################################################################
#
#       安装RabbitMQ
#
####################################################################################################
yum install -y rabbitmq-server
systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service
systemctl status rabbitmq-server.service
systemctl list-unit-files |grep rabbitmq-server.service
rabbitmqctl add_user openstack 123456
rabbitmqctl change_password openstack 123456
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
rabbitmqctl set_user_tags openstack administrator
rabbitmqctl list_users
netstat -ntlp |grep 5672
/usr/lib/rabbitmq/bin/rabbitmq-plugins list
/usr/lib/rabbitmq/bin/rabbitmq-plugins enable rabbitmq_management mochiweb webmachine rabbitmq_web_dispatch amqp_client rabbitmq_management_agent
systemctl restart rabbitmq-server
# 用浏览器登录 http://192.161.17.51:15672/ 默认用户名密码：guest/guest ,管理用户：openstack/123456

####################################################################################################
#
#       安装配置Keystone
#
####################################################################################################
# 创建数据库
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '123456';
EOF

# 测试一下
mysql -Dkeystone -ukeystone -p123456 <<'EOF'
quit
EOF

# 安装keystone和memcached 
yum -y install openstack-keystone httpd mod_wsgi python-openstackclient memcached python-memcached openstack-utils
systemctl enable memcached.service
systemctl restart memcached.service
systemctl status memcached.service
# keystone configure
cp /etc/keystone/keystone.conf /etc/keystone/keystone.conf.bak
>/etc/keystone/keystone.conf
openstack-config --set /etc/keystone/keystone.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/keystone/keystone.conf database connection mysql://keystone:123456@controller1/keystone
openstack-config --set /etc/keystone/keystone.conf cache backend oslo_cache.memcache_pool
openstack-config --set /etc/keystone/keystone.conf cache enabled true
openstack-config --set /etc/keystone/keystone.conf cache memcache_servers controller1:11211
openstack-config --set /etc/keystone/keystone.conf memcache servers controller1:11211
openstack-config --set /etc/keystone/keystone.conf token expiration 3600
openstack-config --set /etc/keystone/keystone.conf token provider fernet
# 配置httpd.conf文件&memcached文件
sed -i "s/#ServerName www.example.com:80/ServerName controller1/" /etc/httpd/conf/httpd.conf
sed -i 's/OPTIONS*.*/OPTIONS="-l 127.0.0.1,::1,10.0.0.51"/' /etc/sysconfig/memcached
# 配置keystone与httpd结合
ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
# 数据库同步
su -s /bin/sh -c "keystone-manage db_sync" keystone
# 初始化fernet
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
# 启动httpd，并设置httpd开机启动
systemctl enable httpd.service 
systemctl restart httpd.service
systemctl status httpd.service
systemctl list-unit-files |grep httpd.service
# 创建 admin 用户角色
keystone-manage bootstrap \
--bootstrap-password admin \
--bootstrap-username admin \
--bootstrap-project-name admin \
--bootstrap-role-name admin \
--bootstrap-service-name keystone \
--bootstrap-region-id RegionOne \
--bootstrap-admin-url http://controller1:35357/v3 \
--bootstrap-internal-url http://controller1:35357/v3 \
--bootstrap-public-url http://controller1:5000/v3 
# 验证：
openstack project list --os-username admin --os-project-name admin --os-user-domain-id default --os-project-domain-id default --os-identity-api-version 3 --os-auth-url http://controller1:5000 --os-password admin
# 创建admin用户环境变量，创建/root/admin-openrc 文件并写入如下内容：
cat <<'EOF' > /root/admin-openrc
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_DOMAIN_ID=default
export OS_USERNAME=admin
export OS_PROJECT_NAME=admin
export OS_PASSWORD=admin
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export OS_AUTH_URL=http://controller1:35357/v3
EOF
# 创建service项目
source /root/admin-openrc
openstack project create --domain default --description "Service Project" service
# 创建demo项目
openstack project create --domain default --description "Demo Project" demo
# 创建demo用户,注意：demo为demo用户密码
openstack user create --domain default demo --password demo
# 创建user角色将demo用户赋予user角色
openstack role create user
openstack role add --project demo --user demo user
# 验证keystone
unset OS_TOKEN OS_URL
openstack --os-auth-url http://controller1:35357/v3 --os-project-domain-name default --os-user-domain-name default --os-project-name admin --os-username admin token issue --os-password admin
openstack --os-auth-url http://controller1:5000/v3 --os-project-domain-name default --os-user-domain-name default --os-project-name demo --os-username demo token issue --os-password demo

####################################################################################################
#
#       安装配置glance
#
####################################################################################################
# 创建数据库
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '123456';
EOF
# 测试一下
mysql -Dglance -uglance -p123456 <<'EOF'
quit
EOF
# 创建glance用户及赋予admin权限
source /root/admin-openrc
openstack user create --domain default glance --password 123456
openstack role add --project service --user glance admin

# 创建image服务
openstack service create --name glance --description "OpenStack Image service" image

# 创建glance的endpoint
openstack endpoint create --region RegionOne image public http://controller1:9292 
openstack endpoint create --region RegionOne image internal http://controller1:9292 
openstack endpoint create --region RegionOne image admin http://controller1:9292

# 安装glance相关rpm包
yum install -y openstack-glance

# 修改glance配置文件/etc/glance/glance-api.conf
# 注意:密码设置成你自己的
cp /etc/glance/glance-api.conf /etc/glance/glance-api.conf.bak
>/etc/glance/glance-api.conf
openstack-config --set /etc/glance/glance-api.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/glance/glance-api.conf database connection mysql+pymysql://glance:123456@controller1/glance 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_uri http://controller1:5000 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://controller1:35357 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers controller1:11211 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_type password 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name default 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name default 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken username glance 
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken password 123456
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_name service
openstack-config --set /etc/glance/glance-api.conf paste_deploy flavor keystone 
openstack-config --set /etc/glance/glance-api.conf glance_store stores file,http 
openstack-config --set /etc/glance/glance-api.conf glance_store default_store file 
openstack-config --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/

# 8、修改glance配置文件/etc/glance/glance-registry.conf：
cp /etc/glance/glance-registry.conf /etc/glance/glance-registry.conf.bak
>/etc/glance/glance-registry.conf
openstack-config --set /etc/glance/glance-registry.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/glance/glance-registry.conf database connection mysql+pymysql://glance:123456@controller1/glance 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri http://controller1:5000 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_url http://controller1:35357 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken memcached_servers controller1:11211 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_type password 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_name default 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_name default 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_name service 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken username glance 
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken password 123456
openstack-config --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

# 9、同步glance数据库
su -s /bin/sh -c "glance-manage db_sync" glance

# 10、启动glance及设置开机启动
systemctl enable openstack-glance-api.service openstack-glance-registry.service 
systemctl restart openstack-glance-api.service openstack-glance-registry.service
systemctl status openstack-glance-api.service openstack-glance-registry.service

# 12、下载测试镜像文件
# wget http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img
wget http://192.161.14.180/openstack/cirros-0.3.4-x86_64-disk.img

# 13、上传镜像到glance
source /root/admin-openrc
glance image-create --name "cirros-0.3.4-x86_64" --file cirros-0.3.4-x86_64-disk.img --disk-format qcow2 --container-format bare --visibility public --progress
#如果做好了一个CentOS6.7系统的镜像，也可以用这命令操作，例：
glance image-create --name "CentOS7.1-x86_64" --file CentOS_7.1.qcow2 --disk-format qcow2 --container-format bare --visibility public --progress

#查看镜像列表：
glance image-list
#或者
openstack image list

####################################################################################################
#
#       安装配置nova
#
####################################################################################################
# 1、创建nova数据库
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE nova;
CREATE DATABASE nova_api;
CREATE DATABASE nova_cell0;
EOF

# 2、创建数据库用户并赋予权限
mysql -uroot -p123456 <<'EOF'
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'controller1' IDENTIFIED BY '123456';
FLUSH PRIVILEGES;
EOF
# 测试一下
mysql -Dnova -unova -p123456 <<'EOF'
quit
EOF
mysql -Dnova_api -unova -p123456 <<'EOF'
quit
EOF
mysql -Dnova_cell0 -unova -p123456 <<'EOF'
quit
EOF

#注：查看授权列表信息 SELECT DISTINCT CONCAT('User: ''',user,'''@''',host,''';') AS query FROM mysql.user;
#取消之前某个授权 REVOKE ALTER ON *.* TO 'root'@'controller1' IDENTIFIED BY '123456';

# 3、创建nova用户及赋予admin权限
source /root/admin-openrc
openstack user create --domain default nova --password 123456
openstack role add --project service --user nova admin

# 4、创建computer服务
openstack service create --name nova --description "OpenStack Compute" compute

# 5、创建nova的endpoint
#openstack endpoint create --region RegionOne compute public http://controller1:8774/v2.1/%\(tenant_id\)s
#openstack endpoint create --region RegionOne compute internal http://controller1:8774/v2.1/%\(tenant_id\)s
#openstack endpoint create --region RegionOne compute admin http://controller1:8774/v2.1/%\(tenant_id\)s
# Create the Compute API service endpoints:
openstack endpoint create --region RegionOne compute public http://controller1:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://controller1:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://controller1:8774/v2.1

# 创建placement用户和placement 服务
openstack user create --domain default placement --password 123456
openstack role add --project service --user placement admin
openstack service create --name placement --description "OpenStack Placement" placement

# 创建placement endpoint
openstack endpoint create --region RegionOne placement public http://controller1:8778
openstack endpoint create --region RegionOne placement admin http://controller1:8778
openstack endpoint create --region RegionOne placement internal http://controller1:8778

# 6、安装nova相关软件
yum install -y openstack-nova-api openstack-nova-conductor openstack-nova-cert openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler openstack-nova-placement-api

# 7、配置nova的配置文件/etc/nova/nova.conf
cp /etc/nova/nova.conf /etc/nova/nova.conf.bak
>/etc/nova/nova.conf
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
openstack-config --set /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata
openstack-config --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/nova/nova.conf DEFAULT my_ip $IP
openstack-config --set /etc/nova/nova.conf DEFAULT use_neutron True
openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
openstack-config --set /etc/nova/nova.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/nova/nova.conf api auth_strategy keystone
openstack-config --set /etc/nova/nova.conf database connection mysql+pymysql://nova:123456@controller1/nova
openstack-config --set /etc/nova/nova.conf api_database connection mysql+pymysql://nova:123456@controller1/nova_api
openstack-config --set /etc/nova/nova.conf scheduler discover_hosts_in_cells_interval 300
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_uri http://controller1:5000
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_url http://controller1:35357
openstack-config --set /etc/nova/nova.conf keystone_authtoken memcached_servers controller1:11211
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_type password
openstack-config --set /etc/nova/nova.conf keystone_authtoken project_domain_name default
openstack-config --set /etc/nova/nova.conf keystone_authtoken user_domain_name default
openstack-config --set /etc/nova/nova.conf keystone_authtoken project_name service
openstack-config --set /etc/nova/nova.conf keystone_authtoken username nova
openstack-config --set /etc/nova/nova.conf keystone_authtoken password 123456
openstack-config --set /etc/nova/nova.conf keystone_authtoken service_token_roles_required True
openstack-config --set /etc/nova/nova.conf vnc vncserver_listen 0.0.0.0
openstack-config --set /etc/nova/nova.conf vnc vncserver_proxyclient_address $IP
openstack-config --set /etc/nova/nova.conf glance api_servers http://controller1:9292
openstack-config --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp
# 把placement 整合到nova.conf里
openstack-config --set /etc/nova/nova.conf placement auth_url http://controller1:35357/v3
openstack-config --set /etc/nova/nova.conf placement memcached_servers controller1:11211
openstack-config --set /etc/nova/nova.conf placement auth_type password
openstack-config --set /etc/nova/nova.conf placement project_domain_name default
openstack-config --set /etc/nova/nova.conf placement user_domain_name default
openstack-config --set /etc/nova/nova.conf placement project_name service
openstack-config --set /etc/nova/nova.conf placement username nova
openstack-config --set /etc/nova/nova.conf placement password 123456
openstack-config --set /etc/nova/nova.conf placement os_region_name RegionOne

# 注意：其他节点上记得替换IP，还有密码，文档红色以及绿色的地方。

# Due to a packaging bug, you must enable access to the Placement API by adding the following configuration to /etc/httpd/conf.d/00-nova-placement-api.conf:
cat <<'EOF' >> /etc/httpd/conf.d/00-nova-placement-api.conf

<Directory /usr/bin>
   <IfVersion >= 2.4>
      Require all granted
   </IfVersion>
   <IfVersion < 2.4>
      Order allow,deny
      Allow from all
   </IfVersion>
</Directory>
EOF

# 重启下httpd服务
systemctl restart httpd
# Populate the nova-api database:
su -s /bin/sh -c "nova-manage api_db sync" nova
# Register the cell0 database:
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
# Create the cell1 cell:
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
# Populate the nova database:
su -s /bin/sh -c "nova-manage db sync" nova
# Verify nova cell0 and cell1 are registered correctly:
nova-manage cell_v2 list_cells
+-------+--------------------------------------+
|  Name |                 UUID                 |
+-------+--------------------------------------+
| cell0 | 00000000-0000-0000-0000-000000000000 |
| cell1 | 6e974171-c973-4de0-90e4-a73af2747931 |
+-------+--------------------------------------+

# 检查下是否配置成功
nova-status upgrade check
# 查看已经创建好的单元格列表
nova-manage cell_v2 list_cells --verbose
# 注意，如果有新添加的计算节点，需要运行下面命令来发现，并且添加到单元格中
nova-manage cell_v2 discover_hosts
# 当然，你可以在控制节点的nova.conf文件里[scheduler]模块下添加 discover_hosts_in_cells_interval=300 这个设置来自动发现


# 10、设置nova相关服务开机启动
systemctl enable openstack-nova-api.service openstack-nova-cert.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service

# 启动nova服务：
systemctl restart openstack-nova-api.service openstack-nova-cert.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service

# 查看nova服务：
systemctl status openstack-nova-api.service openstack-nova-cert.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service

systemctl list-unit-files |grep openstack-nova-*

# 11、验证nova服务
unset OS_TOKEN OS_URL
source /root/admin-openrc
nova service-list 
openstack endpoint list 
# 查看endpoint list
# 看是否有结果正确输出

接著建立 flavor 來提供給 Instance 使用：
openstack flavor create m1.tiny --id 1 --ram 512 --disk 1 --vcpus 1
openstack flavor create m1.small --id 2 --ram 2048 --disk 20 --vcpus 1
openstack flavor create m1.medium --id 3 --ram 4096 --disk 40 --vcpus 2
openstack flavor create m1.large --id 4 --ram 8192 --disk 80 --vcpus 4
openstack flavor create m1.xlarge --id 5 --ram 16384 --disk 160 --vcpus 8
openstack flavor list

####################################################################################################
#
#       安装配置neutron
#
####################################################################################################
# 1、创建neutron数据库
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE neutron;
EOF

# 2、创建数据库用户并赋予权限
mysql -uroot -p123456 <<'EOF'
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '123456';
EOF
# 测试一下
mysql -Dneutron -uneutron -p123456 <<'EOF'
quit
EOF

# 3、创建neutron用户及赋予admin权限
source /root/admin-openrc
openstack user create --domain default neutron --password 123456
openstack role add --project service --user neutron admin

4、创建network服务
openstack service create --name neutron --description "OpenStack Networking" network

5、创建endpoint
openstack endpoint create --region RegionOne network public http://controller1:9696
openstack endpoint create --region RegionOne network internal http://controller1:9696
openstack endpoint create --region RegionOne network admin http://controller1:9696

6、安装neutron相关软件
yum install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch ebtables

7、配置neutron配置文件/etc/neutron/neutron.conf （配置服务组件）
cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.bak
>/etc/neutron/neutron.conf
openstack-config --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
openstack-config --set /etc/neutron/neutron.conf DEFAULT service_plugins router
openstack-config --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips true
openstack-config --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/neutron/neutron.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes true
openstack-config --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes true
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_uri http://controller1:5000
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://controller1:35357 
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers controller1:11211
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_type password
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name default
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name default
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_name service
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken username neutron
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken password 123456
openstack-config --set /etc/neutron/neutron.conf database connection mysql+pymysql://neutron:123456@controller1/neutron
openstack-config --set /etc/neutron/neutron.conf nova auth_url http://controller1:35357
openstack-config --set /etc/neutron/neutron.conf nova auth_type password
openstack-config --set /etc/neutron/neutron.conf nova project_domain_name default
openstack-config --set /etc/neutron/neutron.conf nova user_domain_name default
openstack-config --set /etc/neutron/neutron.conf nova region_name RegionOne
openstack-config --set /etc/neutron/neutron.conf nova project_name service
openstack-config --set /etc/neutron/neutron.conf nova username nova
openstack-config --set /etc/neutron/neutron.conf nova password 123456
openstack-config --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lib/neutron/tmp

8、配置/etc/neutron/plugins/ml2/ml2_conf.ini （配置 Modular Layer 2 (ML2) 插件）
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers flat,vlan,vxlan 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers openvswitch,l2population 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers port_security 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vxlan 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 path_mtu 1500
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks provider
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan vni_ranges 1:1000 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vxlan firewall_driver iptables_hybrid
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset true
#openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers openvswitch,l2population 
#openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 physical_network_mtus physnet1:1500,physnet2:1500
#openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks *
#openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_gre tunnel_id_ranges 1:1000 
#openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_vlan network_vlan_ranges physnet1,physnet2:1000:1030 

9、配置/etc/neutron/plugins/ml2/openvswitch_agent.ini （配置openvswitch代理）
PROVIDER=br-provider
INT=br-int
TUN=br-tun
NIC1=eth1
NIC2=eth2
NIC2_IP=`LANG=C ip addr show dev $NIC2 | grep 'inet '| grep $NIC2$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
echo $NIC2_IP
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini DEFAULT debug false
#openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings provider:$PROVIDER,integration:$INT,tunnel:$TUN
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs bridge_mappings provider:$PROVIDER,integration:$INT
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs local_ip $NIC2_IP
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini ovs of_interface ovs-ofctl
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent tunnel_types vxlan
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini agent l2_population True 
openstack-config --set /etc/neutron/plugins/ml2/openvswitch_agent.ini securitygroup enable_security_group true 

# 注意: eno16777736(修改后为eth1)是连接外网的网卡，一般这里写的网卡名都是能访问外网的，如果不是外网网卡，那么VM就会与外界网络隔离。
# local_ip 定义的是隧道网络，vxLan下 vm-openvswitch->vxlan ------tun-----vxlan->openvswitch-vm

# 创建OVS provider bridge 
a)
# 防止错误：ovs-vsctl: unix:/var/run/openvswitch/db.sock: database connection failed (No such file or directory)
systemctl enable openvswitch
systemctl restart openvswitch
systemctl status openvswitch
b) 修改网络接口配置文件
NIC1=eth1
NIC2=eth2
NIC1_IP=`LANG=C ip addr show dev $NIC1 | grep 'inet '| grep $NIC1$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
NIC2_IP=`LANG=C ip addr show dev $NIC2 | grep 'inet '| grep $NIC2$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
echo $NIC1_IP
echo $NIC2_IP
cat <<EOF > /etc/sysconfig/network-scripts/ifcfg-br-provider
DEVICE=br-provider
BOOTPROTO=static
ONBOOT=yes
NM_CONTROLLED=no
IPADDR=$NIC1_IP
GATEWAY=192.161.17.1
NETMASK=255.255.255.0
DNS1=192.168.1.12
TYPE=OVSBridge       # 指定为OVSBridge类型   
DEVICETYPE=ovs        # 设备类型是ovs   
EOF

cat <<EOF > /etc/sysconfig/network-scripts/ifcfg-eth1
DEVICE=eth1
ONBOOT=yes
NM_CONTROLLED=no
TYPE=OVSPort            # 指定为OVSPort类型  
DEVICETYPE=ovs        # 设备类型是ovs  
OVS_BRIDGE=br-provider    # 和ovs bridge关联   
EOF

service network restart
c)创建OVS provider bridge
ovs-vsctl add-br br-provider
ovs-vsctl add-port br-provider eth1
(eth1为PROVIDER_INTERFACE)


# 10、配置 /etc/neutron/l3_agent.ini  (配置layer-3代理)
#openstack-config --set /etc/neutron/l3_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.BridgeInterfaceDriver 
openstack-config --set /etc/neutron/l3_agent.ini DEFAULT debug false
openstack-config --set /etc/neutron/l3_agent.ini DEFAULT interface_driver openvswitch
openstack-config --set /etc/neutron/l3_agent.ini DEFAULT external_network_bridge ""

11、配置/etc/neutron/dhcp_agent.ini (配置DHCP代理)
#openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.BridgeInterfaceDriver
#openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
#openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata true
#openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT verbose true
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT debug false
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver openvswitch
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata true

12、重新配置/etc/nova/nova.conf，配置这步的目的是让compute节点能使用上neutron网络
openstack-config --set /etc/nova/nova.conf neutron url http://controller1:9696 
openstack-config --set /etc/nova/nova.conf neutron auth_url http://controller1:35357 
openstack-config --set /etc/nova/nova.conf neutron auth_plugin password 
openstack-config --set /etc/nova/nova.conf neutron project_domain_id default 
openstack-config --set /etc/nova/nova.conf neutron user_domain_id default 
openstack-config --set /etc/nova/nova.conf neutron region_name RegionOne
openstack-config --set /etc/nova/nova.conf neutron project_name service 
openstack-config --set /etc/nova/nova.conf neutron username neutron 
openstack-config --set /etc/nova/nova.conf neutron password 123456
openstack-config --set /etc/nova/nova.conf neutron service_metadata_proxy true 
openstack-config --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret 123456

13、将dhcp-option-force=26,1450写入/etc/neutron/dnsmasq-neutron.conf
echo "dhcp-option-force=26,1450" >/etc/neutron/dnsmasq-neutron.conf

14、配置/etc/neutron/metadata_agent.ini
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_ip controller1
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret 123456
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT metadata_workers 4
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT verbose true
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT debug false
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_protocol http

15、创建软链接
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

16、同步数据库
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

17、重启nova服务，因为刚才改了nova.conf
systemctl restart openstack-nova-api.service
systemctl status openstack-nova-api.service

18、重启neutron服务并设置开机启动
systemctl enable neutron-server.service neutron-openvswitch-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service 
systemctl restart neutron-server.service neutron-openvswitch-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
systemctl status neutron-server.service neutron-openvswitch-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service

19、启动neutron-l3-agent.service并设置开机启动
systemctl enable neutron-l3-agent.service 
systemctl restart neutron-l3-agent.service
systemctl status neutron-l3-agent.service

20、执行验证
source /root/admin-openrc
neutron ext-list
neutron agent-list

21、创建vxLan模式网络，让虚拟机能外出
a. 首先先执行环境变量
source /root/admin-openrc

b. 创建flat模式的provider网络，注意这个provider是外出网络，必须是flat模式的
openstack network create --share --external --provider-physical-network provider \
  --provider-network-type flat provider1
#neutron --debug net-create --shared provider --router:external true --provider:network_type flat --provider:physical_network provider
修改命令：
openstack network set --external provider1
#neutron --debug net-update provider --router:external
# 执行完这步，在界面里进行操作，把public网络设置为共享和外部网络

c. 创建public网络子网，名为public-sub，网段就是192.161.17，并且IP范围是51-80（这个一般是给VM用的floating IP了），dns设置为192.168.1.12，网关为192.161.17.1
openstack subnet create --subnet-range 192.161.17.0/24 --gateway 192.161.17.1 \
  --network provider1 --allocation-pool start=192.161.17.65,end=192.161.17.80 \
  --dns-nameserver 192.168.1.12 \
  --no-dhcp \
  provider1-v4
#neutron subnet-create provider 192.161.17.0/24 --name provider-sub --allocation-pool start=192.161.17.65,end=192.161.17.80 --dns-nameserver 192.168.1.12 --gateway 192.161.17.1

d. 创建名为private的私有网络, 网络模式为vxlan
openstack network create --share --internal \
  --provider-network-type vxlan \
  private1
openstack network create --share --internal \
  --provider-network-type vxlan \
  private2
#neutron net-create private --provider:network_type vxlan --router:external False --shared

e. 创建私有网络子网,网段就是虚拟机获取的私有的IP地址
openstack subnet create private1-v4-1 \
  --network private1 \
  --subnet-range 172.16.1.0/24 \
  --gateway 172.16.1.1 \
  --dns-nameserver 192.168.1.12 
openstack subnet create private2-v4-1 \
  --network private2 \
  --subnet-range 172.16.2.0/24 \
  --gateway 172.16.2.1 \
  --dns-nameserver 192.168.1.12 
openstack subnet create private2-v4-2 \
  --network private2 \
  --subnet-range 172.16.3.0/24 \
  --gateway 172.16.3.1 \
  --dns-nameserver 192.168.1.12 

#neutron subnet-create private1 --name private1-v4-1 --gateway 172.16.1.1 172.16.1.0/24 \
#  --dns-nameserver 192.168.1.12
#neutron subnet-create private2 --name private2-v4-1 --gateway 172.16.2.1 172.16.2.0/24 \
#  --dns-nameserver 192.168.1.12

f. 创建路由
openstack router create router01
#neutron router-create router01
# 在路由器添加一个私网子网接口：
openstack router add subnet router01 private1-v4-1
openstack router add subnet router01 private2-v4-1
openstack router add subnet router01 private2-v4-2
#neutron router-interface-add router01 private1-v4-1
#neutron router-interface-add router01 private2-v4-1
# 在路由器上设置外部网络的网关：
openstack router set router01 --external-gateway provider1
#neutron router-gateway-set router01 --external-gateway provider1

g. 验证网络使用操作
source admin-openrc.sh
# network id
provider1_netID=`openstack network list | grep provider1 | awk '{ print $2 }'`
private1_netID=`openstack network list | grep private1 | awk '{ print $2 }'`
private2_netID=`openstack network list | grep private2 | awk '{ print $2 }'`
# subnet id
private1_1_subnetID=`openstack subnet list | grep private1-v4-1 | awk '{ print $2 }'`
private2_1_subnetID=`openstack subnet list | grep private2-v4-1 | awk '{ print $2 }'`
private2_2_subnetID=`openstack subnet list | grep private2-v4-2 | awk '{ print $2 }'`

openstack flavor create m1.tiny --id 1 --ram 512 --disk 1 --vcpus 1
openstack flavor create m1.small --id 2 --ram 2048 --disk 20 --vcpus 1
openstack flavor create m1.medium --id 3 --ram 4096 --disk 40 --vcpus 2
openstack flavor create m1.large --id 4 --ram 8192 --disk 80 --vcpus 4
openstack flavor create m1.xlarge --id 5 --ram 16384 --disk 160 --vcpus 8
openstack flavor list

openstack image list 

openstack server create --image cirros-0.3.4-x86_64 --flavor m1.tiny --security-group default --nic net-id=provider1 testvm1
openstack server create --image cirros-0.3.4-x86_64 --flavor m1.tiny --security-group default --nic net-id=private1 test1
openstack server create --image cirros-0.3.4-x86_64 --flavor m1.tiny --security-group default --nic net-id=private2 test2

openstack server list

# alloc new floating ip
floating_ip1=`openstack floating ip create provider1 | grep floating_ip_address | awk -F '|' '{ print $3 }'`
openstack floating ip list
echo $floating_ip1
# retrive free floating ip
floating_ip1=`openstack floating ip list --status DOWN | grep '| None             | None |' | head -n 1 | awk -F '|' '{ print $3 }'`
echo $floating_ip1
floating_ip2=`openstack floating ip list --status DOWN | grep '| None             | None |' | head -n 1 | awk -F '|' '{ print $3 }'`
echo $floating_ip2
# assign floating ip to a vm server instance
openstack server add floating ip test1 $floating_ip1
openstack server add floating ip test2 $floating_ip2
openstack floating ip show $floating_ip1
openstack floating ip show $floating_ip2

openstack port list --router router01
openstack port list --network private1
openstack port list --network private2
openstack port list --server testvm1
openstack port list --server test1
openstack port list --server test2
openstack port list --device-owner network:dhcp

# Configure security settings like follows to access with SSH and ICMP.
openstack security group list
openstack security group list --project admin

# 多租户下，admin用户，会出现错误：
# More than one SecurityGroup exists with the name 'default'.
SecurityGroup_ID=`openstack security group list --project admin | grep 'default' | head -n 1 | awk -F '|' '{ print $2 }'`
echo $SecurityGroup_ID
# permit ICMP
openstack security group rule create --protocol icmp --ingress $SecurityGroup_ID 
openstack security group rule create --proto icmp default $SecurityGroup_ID 
# permit SSH
openstack security group rule create --protocol tcp --dst-port 22:22 $SecurityGroup_ID 
openstack security group rule create --proto tcp --dst-port 22 default $SecurityGroup_ID 
# list security group
openstack security group rule list $SecurityGroup_ID 

22、检查网络服务
# neutron agent-list
看服务是否是笑脸:）

# 《《《当添加了计算节点的网络配置后，进行验证的命令》》》》
. admin-openrc
# 列出加载的扩展来验证``neutron-server``进程是否正常启动：
openstack extension list --network

# 网络选项2：自服务网络：列出代理以验证启动 neutron 代理是否成功：
#（输出结果应该包括控制节点上的四个代理和每个计算节点上的一个代理。）
openstack network agent list
+----------------------+--------------------+-------------------+-------------------+-------+-------+----------------------+
| ID                   | Agent Type         | Host              | Availability Zone | Alive | State | Binary               |
+----------------------+--------------------+-------------------+-------------------+-------+-------+----------------------+
| 3a526454-eb2e-48fd-  | Linux bridge agent | compute2.local    | None              | true  | UP    | neutron-linuxbridge- |
| b37d-161f7b85b485    |                    |                   |                   |       |       | agent                |
| 565b0312-ee56-4caa-9 | Metadata agent     | controller1.local | None              | true  | UP    | neutron-metadata-    |
| 105-74d570b0d4ab     |                    |                   |                   |       |       | agent                |
| 79e0a489-1239-46df-  | Linux bridge agent | controller1.local | None              | true  | UP    | neutron-linuxbridge- |
| b4e2-cbbbae7a99cd    |                    |                   |                   |       |       | agent                |
| 9ae23fd8-902e-4438   | L3 agent           | controller1.local | nova              | true  | UP    | neutron-l3-agent     |
| -a12b-69121abb703e   |                    |                   |                   |       |       |                      |
| aeeeb2cf-63ff-4272-b | DHCP agent         | controller1.local | nova              | true  | UP    | neutron-dhcp-agent   |
| fb6-88a293c5af92     |                    |                   |                   |       |       |                      |
| f9f7b91a-6fff-49f8-a | Linux bridge agent | compute1.local    | None              | true  | UP    | neutron-linuxbridge- |
| f23-a3b9e716db04     |                    |                   |                   |       |       | agent                |
+----------------------+--------------------+-------------------+-------------------+-------+-------+----------------------+

####################################################################################################
#
#       安装Dashboard
#
####################################################################################################
1、安装dashboard相关软件包
yum install -y openstack-dashboard

2、修改配置文件/etc/openstack-dashboard/local_settings
(已修改好的文件直接下载：
mv /etc/openstack-dashboard/local_settings /etc/openstack-dashboard/local_settings.bak
wget -O /etc/openstack-dashboard/local_settings http://192.161.14.180/openstack/local_settings
)
# vi /etc/openstack-dashboard/local_settings
加入或者修改为以下內容：
OPENSTACK_HOST = "10.0.0.51"
ALLOWED_HOSTS = ['*']
CACHES = {
'default': {
'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache'
'LOCATION': '127.0.0.1:11211',
}
}
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'default'

OPENSTACK_API_VERSIONS = {
    "data-processing": 1.1,
    "identity": 3,
    "image": 2,
    "volume": 2,
    "compute": 2,
}
TIME_ZONE = "Asia/Shanghai"

3、启动dashboard服务并设置开机启动
# 由于禁用ipv6，需要去除相应的地址
 sed -i 's/,::1,/,/g' /etc/sysconfig/memcached
# 重启服务
systemctl restart httpd.service memcached.service
systemctl status httpd.service memcached.service


到此，Controller节点搭建完毕，打开firefox浏览器即可访问http://controller1.local/dashboard(在客户端/etc/hosts中配置下名字解析)可进入openstack界面！


####################################################################################################
#
#       安装配置cinder
#
####################################################################################################
<********************controller1节点操作*************************************************************
1、创建数据库用户并赋予权限
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '123456';
EOF
# 测试一下
mysql -Dcinder -ucinder -p123456 <<'EOF'
quit
EOF

2、创建cinder用户并赋予admin权限
source /root/admin-openrc
openstack user create --domain default cinder --password 123456
openstack role add --project service --user cinder admin

3、创建volume服务
#openstack service create --name cinder --description "OpenStack Block Storage" volume
openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3
4、创建endpoint
#openstack endpoint create --region RegionOne volume public http://controller1:8776/v1/%\(tenant_id\)s
#openstack endpoint create --region RegionOne volume internal http://controller1:8776/v1/%\(tenant_id\)s
#openstack endpoint create --region RegionOne volume admin http://controller1:8776/v1/%\(tenant_id\)s
#openstack endpoint create --region RegionOne volumev2 public http://controller1:8776/v2/%\(tenant_id\)s
#openstack endpoint create --region RegionOne volumev2 internal http://controller1:8776/v2/%\(tenant_id\)s
#openstack endpoint create --region RegionOne volumev2 admin http://controller1:8776/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  volumev2 public http://controller1:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev2 internal http://controller1:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev2 admin http://controller1:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev3 public http://controller1:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev3 internal http://controller1:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne \
  volumev3 admin http://controller1:8776/v3/%\(project_id\)s
5、安装cinder相关服务
yum install -y openstack-cinder

6、配置cinder配置文件
cp /etc/cinder/cinder.conf /etc/cinder/cinder.conf.bak
>/etc/cinder/cinder.conf
openstack-config --set /etc/cinder/cinder.conf DEFAULT my_ip 10.0.0.51
openstack-config --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/cinder/cinder.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/cinder/cinder.conf database connection mysql+pymysql://cinder:123456@controller1/cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://controller1:5000
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://controller1:35357
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers controller1:11211
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_type password
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_name service
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password 123456
openstack-config --set /etc/cinder/cinder.conf oslo_concurrency lock_path /var/lib/cinder/tmp

7、初始化块设备服务的数据库
su -s /bin/sh -c "cinder-manage db sync" cinder

8、Configure Compute to use Block Storage
openstack-config --set /etc/nova/nova.conf cinder os_region_name RegionOne

9、Restart the Compute API service
systemctl restart openstack-nova-api.service

10、在controller1上启动cinder服务，并设置开机启动
systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service 
systemctl restart openstack-cinder-api.service openstack-cinder-scheduler.service 
systemctl status openstack-cinder-api.service openstack-cinder-scheduler.service

# 可选安装2：***Install and configure the backup service***
# modify local_settings
sed -i "s/'enable_backup': False,/'enable_backup': True,/g" /etc/openstack-dashboard/local_settings
# restart servce
systemctl restart httpd.service memcached.service
systemctl status httpd.service memcached.service

*********************controller1节点操作*************************************************************>
<********************cinder1节点操作*************************************************************
1、安装Cinder节点，Cinder节点这里我们需要额外的添加一个硬盘（/dev/sdb)用作cinder的存储服务 (注意！这一步是在cinder节点操作的）
yum install -y lvm2

2、启动服务并设置为开机自启 (注意！这一步是在cinder节点操作的）
systemctl enable lvm2-lvmetad.service
systemctl start lvm2-lvmetad.service
systemctl status lvm2-lvmetad.service

3、创建lvm, 这里的/dev/sdb就是额外添加的硬盘 (注意！这一步是在cinder节点操作的）
fdisk -l
pvcreate /dev/sdb
vgcreate cinder-volumes /dev/sdb

4. 编辑存储节点lvm.conf文件 (注意！这一步是在cinder节点操作的）
vi /etc/lvm/lvm.conf
在devices 下面添加 filter = [ "a/sda/", "a/sdb/", "r/.*/"] ，130行 ：
sed -i '142i\        filter = [ "a/sda/", "a/sdb/", "r/.*/"]' /etc/lvm/lvm.conf

然后重启下lvm2服务：
systemctl restart lvm2-lvmetad.service
systemctl status lvm2-lvmetad.service

5、安装openstack-cinder、targetcli (注意！这一步是在cinder节点操作的）
yum install -y openstack-cinder openstack-utils targetcli python-keystone

6、配置cinder配置文件 (注意！这一步是在cinder节点操作的）
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
cp /etc/cinder/cinder.conf /etc/cinder/cinder.conf.bak
>/etc/cinder/cinder.conf 
openstack-config --set /etc/cinder/cinder.conf DEFAULT debug false
openstack-config --set /etc/cinder/cinder.conf DEFAULT verbose false
openstack-config --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
# my_ip = MANAGEMENT_INTERFACE_IP_ADDRESS
openstack-config --set /etc/cinder/cinder.conf DEFAULT my_ip $IP
openstack-config --set /etc/cinder/cinder.conf DEFAULT enabled_backends lvm
openstack-config --set /etc/cinder/cinder.conf DEFAULT glance_api_servers http://controller1:9292
#openstack-config --set /etc/cinder/cinder.conf DEFAULT glance_api_version 2
#openstack-config --set /etc/cinder/cinder.conf DEFAULT enable_v1_api true
#openstack-config --set /etc/cinder/cinder.conf DEFAULT enable_v2_api true
#openstack-config --set /etc/cinder/cinder.conf DEFAULT enable_v3_api true
#openstack-config --set /etc/cinder/cinder.conf DEFAULT storage_availability_zone nova
#openstack-config --set /etc/cinder/cinder.conf DEFAULT default_availability_zone nova
#openstack-config --set /etc/cinder/cinder.conf DEFAULT os_region_name RegionOne
#openstack-config --set /etc/cinder/cinder.conf DEFAULT api_paste_config /etc/cinder/api-paste.ini
openstack-config --set /etc/cinder/cinder.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/cinder/cinder.conf database connection mysql+pymysql://cinder:123456@controller1/cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://controller1:5000
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://controller1:35357
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken memcached_servers controller1:11211
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_type password
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_domain_name default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken user_domain_name default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_name service
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password 123456
# configure the LVM back end with the LVM driver,cinder-volumes volume group
openstack-config --set /etc/cinder/cinder.conf lvm volume_driver cinder.volume.drivers.lvm.LVMVolumeDriver
openstack-config --set /etc/cinder/cinder.conf lvm volume_backend_name lvm
openstack-config --set /etc/cinder/cinder.conf lvm volume_group cinder-volumes
openstack-config --set /etc/cinder/cinder.conf lvm iscsi_protocol iscsi
openstack-config --set /etc/cinder/cinder.conf lvm iscsi_helper lioadm
openstack-config --set /etc/cinder/cinder.conf oslo_concurrency lock_path /var/lib/cinder/tmp

7、启动openstack-cinder-volume和target并设置开机启动 (注意！这一步是在cinder节点操作的）
systemctl enable openstack-cinder-volume.service target.service 
systemctl restart openstack-cinder-volume.service target.service 
systemctl status openstack-cinder-volume.service target.service

#添加使用NFS共享
1、安装软件包
yum install -y nfs-utils

# 编辑/etc/idmapd.conf，添加自定义域名：
vi /etc/idmapd.conf
在5行添加内容：
sed -i '6i\Domain = local' /etc/idmapd.conf

2、创建/etc/cinder/nfs_shares文件，并写入如下内容
# echo "<SERVER>:/<share>" > /etc/cinder/nfs_shares
echo '10.0.0.61:/data'  > /etc/cinder/nfs_shares
格式： 
HOST 填写IP地址或是NFS服务器的主机名。 
SHARE使已经存在的且可访问的NFS共享的绝对路径。 
具体可以用showmount -e 10.0.0.61查看

3、设置/etc/cinder/nfs_shares的属主为root用户，组为cinder。
chown cinder:cinder /etc/cinder/nfs_shares

4、设置/etc/cinder/nfs_shares为可由组cinder成员可读
chmod 0640 /etc/cinder/nfs_shares

#5、创建mount目录
#mkdir /var/lib/cinder/mnt
#chown -v cinder.cinder /var/lib/cinder/mnt

5、配置/etc/cinder/cinder.conf
# 启用lvm和nfs的backends（可以同时启用多种后端存储，以逗号隔开）
openstack-config --set /etc/cinder/cinder.conf DEFAULT enabled_backends lvm,nfs
openstack-config --set /etc/cinder/cinder.conf nfs volume_driver cinder.volume.drivers.nfs.NfsDriver
openstack-config --set /etc/cinder/cinder.conf nfs volume_backend_name nfs
openstack-config --set /etc/cinder/cinder.conf nfs nfs_shares_config /etc/cinder/nfs_shares
#openstack-config --set /etc/cinder/cinder.conf nfs nfs_mount_point_base /var/lib/cinder/mnt

#Verify the changes
cat /etc/cinder/nfs_shares
grep -i nfs /etc/cinder/cinder.conf | grep -v \#
 
6、（可选），添加额外的NFS挂载点属性需要在你的环境中设置/etc/cinder/ 
cinder.conf的nfs_mount_options 键值。如果你的NFS共享无须任何额外的挂载属性(或 
者是你不能确定)的话，请忽略此步。
openstack-config --set /etc/cinder/cinder.conf nfs nfs_mount_options OPTIONS

8、（可选）配置卷是否作为稀疏文件创建并按需要分配或完全预先分配
openstack-config --set /etc/cinder/cinder.conf nfs nfs_sparsed_volumes false
#nfs_sparsed_volumes 配置关键字定义了卷是否作为稀疏文件创建并按需要分 
#配或完全预先分配。默认和建议的值为 true，它会保证卷初始化创建为稀疏文件。 
#设置 nfs_sparsed_volumes为false的结果就是在卷创建的时候就完全分配了。 
#这会导致卷创建时间的延长。 

#如果客户端主机启用了SELinux，若此主机需要访问NFS共享上的实例的话就需要 
#设置virt_use_nfs布尔值。以root用户运行下面的命令：
setsebool -P virt_use_nfs on
setsebool virt_use_nfs

9、重启cinder 卷服务：
systemctl restart openstack-cinder-volume.service target.service 
systemctl status openstack-cinder-volume.service target.service
#for i in $( systemctl list-unit-files | awk ' /cinder/ { print $1 }'); do systemctl restart $i; done
#for i in $( systemctl list-unit-files | awk ' /cinder/ { print $1 }'); do systemctl status $i; done


10、在使用multi-backends创建盘之前，需要先创建卷的类型，dashboard及命令行cinder type-create都可以创建 
#创建LVM
openstack volume type create LVM
cinder type-key LVM set volume_backend_name=lvm

#创建NFS
openstack volume type create NFS
cinder type-key NFS set volume_backend_name=nfs

# 查看配置
openstack volume type list 
+--------------------------------------+------+-----------+
| ID                                   | Name | Is Public |
+--------------------------------------+------+-----------+
| 0c24ef4d-0d2b-4efc-9144-4e6c716ae570 | NFS  | True      |
| 5405bd80-4564-496b-9913-360df1762711 | LVM  | True      |
+--------------------------------------+------+-----------+
cinder extra-specs-list 
+--------------------------------------+------+--------------------------------+
| ID                                   | Name | extra_specs                    |
+--------------------------------------+------+--------------------------------+
| 0c24ef4d-0d2b-4efc-9144-4e6c716ae570 | NFS  | {'volume_backend_name': 'nfs'} |
| 5405bd80-4564-496b-9913-360df1762711 | LVM  | {'volume_backend_name': 'lvm'} |
+--------------------------------------+------+--------------------------------+

# 可选安装1：***Configure with multiple NFS servers(配置多个NFS服务)***
mkdir /data-new1
mkdir /data-new2
echo '10.0.0.61:/data-new1'  >> /etc/cinder/nfs_shares
echo '10.0.0.61:/data-new2'  >> /etc/cinder/nfs_shares
systemctl restart openstack-cinder-volume.service target.service 
systemctl status openstack-cinder-volume.service target.service

# 可选安装2：***Install and configure the backup service***
# (1)必须在cinder存储节点配置安装
# (2)该配置依赖于对象存储服务swift
# 1、确认已安装openstack-cinder
yum install -y openstack-cinder
# 2、查询对象存储的URL
openstack catalog show object-store
# 3、Edit the /etc/cinder/cinder.conf file
openstack-config --set /etc/cinder/cinder.conf DEFAULT backup_driver cinder.backup.drivers.swift
openstack-config --set /etc/cinder/cinder.conf DEFAULT backup_swift_url http://controller1:8080/v1
# 4、启动备份服务
systemctl enable openstack-cinder-backup.service
systemctl restart openstack-cinder-backup.service
systemctl status openstack-cinder-backup.service

********************cinder1节点操作*************************************************************>
<********************nfs1节点操作*************************************************************
1、安装软件包
yum install -y nfs-utils

2、创建共享目录
mkdir /data

3、赋予权限
cp /etc/exports /etc/exports.orig
chmod 777 /data

4、配置NFS
#echo '/data  10.0.0.0/24(rw,sync,no_root_squash)' >/etc/exports
echo '/data  *(rw,sync,no_root_squash)' >/etc/exports
exportfs -rav
#10.0.0.0/24为共享存储的网段, *标识任意网段 

5、启动服务，并设置开机启动
systemctl enable rpcbind.service nfs-server.service
systemctl start rpcbind.service nfs-server.service
systemctl status rpcbind.service nfs-server.service

6、 verify the share is exported:
showmount -e localhost

# 可选安装1：***Configure with multiple NFS servers(配置多个NFS服务)***
mkdir /data-new1
mkdir /data-new2
chmod 777 /data-new1
chmod 777 /data-new2
echo '/data-new1  10.0.0.0/24(rw,sync,no_root_squash)' >>/etc/exports
echo '/data-new2  10.0.0.0/24(rw,sync,no_root_squash)' >>/etc/exports
exportfs -rav
systemctl start rpcbind.service nfs-server.service
systemctl status rpcbind.service nfs-server.service
showmount -e localhost


********************nfs1节点操作*************************************************************>
<********************compute节点操作************************************
# 配置计算节点以使用块设备存储
# 编辑文件 /etc/nova/nova.conf 并添加如下到其中(每个compute节点都需要配置)：
openstack-config --set /etc/nova/nova.conf cinder os_region_name RegionOne

# 重启计算服务：
systemctl restart openstack-nova-compute.service
********************compute节点操作*************************************************************>
<********************客户端节点操作************************************
# 验证cinder服务是否正常
# 列出服务组件以验证是否每个进程都成功启动：
source /root/admin-openrc
cinder service-list
+------------------+-------------------+------+---------+-------+----------------------------+-----------------+
| Binary           | Host              | Zone | Status  | State | Updated_at                 | Disabled Reason |
+------------------+-------------------+------+---------+-------+----------------------------+-----------------+
| cinder-scheduler | controller1.local | nova | enabled | up    | 2017-08-07T06:00:14.000000 | -               |
| cinder-volume    | cinder1.local@lvm | nova | enabled | up    | 2017-08-07T06:00:11.000000 | -               |
+------------------+-------------------+------+---------+-------+----------------------------+-----------------+

openstack volume service list
+------------------+-------------------+------+---------+-------+----------------------------+
| Binary           | Host              | Zone | Status  | State | Updated At                 |
+------------------+-------------------+------+---------+-------+----------------------------+
| cinder-scheduler | controller1.local | nova | enabled | up    | 2017-08-07T06:00:14.000000 |
| cinder-volume    | cinder1.local@lvm | nova | enabled | up    | 2017-08-07T06:00:11.000000 |
+------------------+-------------------+------+---------+-------+----------------------------+

测试卷管理
openstack volume create --type LVM --size 2 disk_lvm1 
openstack volume create --type NFS --size 2 disk_nfs1 
openstack volume list 
openstack volume delete disk_lvm1
# Attache volume to an instance.
openstack server list 
+--------------------------------------+---------+--------+-------------------------------------+---------------------+----------+
| ID                                   | Name    | Status | Networks                            | Image               | Flavor   |
+--------------------------------------+---------+--------+-------------------------------------+---------------------+----------+
| e150b09c-a764-4cea-9241-36529a6c423d | test2   | ACTIVE | private2=172.16.2.12, 192.161.17.76 | cirros-0.3.4-x86_64 | m1.tiny  |
| 847b794e-ad3e-4cf8-a0d2-a866925a7c48 | test1   | ACTIVE | private1=172.16.1.11, 192.161.17.71 | cirros-0.3.4-x86_64 | m1.tiny  |
| 3155c808-1de7-414d-b9d4-02bb7a22871b | testvm1 | ACTIVE | provider1=192.161.17.67             | cirros-0.3.4-x86_64 | m1.small |
+--------------------------------------+---------+--------+-------------------------------------+---------------------+----------+
openstack server add volume testvm1 disk_lvm1
openstack server add volume testvm1 disk_nfs1

# the status of attached disk turns "in-use" like follows
openstack volume list
+--------------------------------------+-----------+-----------+------+----------------------------------+
| ID                                   | Name      | Status    | Size | Attached to                      |
+--------------------------------------+-----------+-----------+------+----------------------------------+
| 897e1d1e-b650-4c13-b9f2-dfed8ff52fbc | disk_nfs1 | in-use    |    2 | Attached to testvm1 on /dev/vdc  |
| e374de89-c33b-444c-916c-7e7cab9b2457 | disk_lvm1 | in-use    |    1 | Attached to testvm1 on /dev/vdb  |
| 4b49c36d-bd07-4d90-a91b-3de52c7a2784 | vol1      | available |    1 |                                  |
+--------------------------------------+-----------+-----------+------+----------------------------------+

# detach the disk
openstack server remove volume testvm1 disk_lvm1 

********************客户端节点操作*************************************************************>
####################################################################################################
#
#       安装配置swift对象存储
#
####################################################################################################
<********************controller1节点操作*************************************************************
# Object Storage service does not use an SQL database on the controller node. 
# Instead, it uses distributed SQLite databases on each storage node.
1、创建cinder用户并赋予admin权限
source /root/admin-openrc
openstack user create --domain default swift --password 123456
openstack role add --project service --user swift admin

2、创建swift服务
openstack service create --name swift --description "OpenStack Object Storage" object-store

3、创建endpoint
openstack endpoint create --region RegionOne \
  object-store public http://controller1:8080/v1/AUTH_%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  object-store internal http://controller1:8080/v1/AUTH_%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  object-store admin http://controller1:8080/v1

4、安装swift相关服务
yum install -y openstack-swift-proxy python-swiftclient \
  python-keystoneclient python-keystonemiddleware \
  memcached

5、配置cinder配置文件(/etc/swift/proxy-server.conf)
curl -o /etc/swift/proxy-server.conf \
  https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=stable/ocata
openstack-config --set /etc/swift/proxy-server.conf DEFAULT bind_port 8080
openstack-config --set /etc/swift/proxy-server.conf DEFAULT user swift
openstack-config --set /etc/swift/proxy-server.conf DEFAULT swift_dir /etc/swift
# Do not change the order of the modules.
openstack-config --set /etc/swift/proxy-server.conf pipeline:main pipeline "catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server"
openstack-config --set /etc/swift/proxy-server.conf app:proxy-server use egg:swift#proxy 
openstack-config --set /etc/swift/proxy-server.conf app:proxy-server account_autocreate True
openstack-config --set /etc/swift/proxy-server.conf filter:keystoneauth use egg:swift#keystoneauth 
openstack-config --set /etc/swift/proxy-server.conf filter:keystoneauth operator_roles admin,user
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken paste.filter_factory keystonemiddleware.auth_token:filter_factory
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken auth_uri http://controller1:5000
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken auth_url http://controller1:35357
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken memcached_servers controller1:11211
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken auth_type password
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken project_domain_name default
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken user_domain_name default
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken project_name service
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken username swift
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken password 123456
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken delay_auth_decision True
openstack-config --set /etc/swift/proxy-server.conf filter:cache use egg:swift#memcache
openstack-config --set /etc/swift/proxy-server.conf filter:cache memcache_servers controller1:11211

*********************controller1节点操作*************************************************************>
<********************object节点操作*************************************************************
# 【每个object节点都需要执行以下步骤】
# 每个object节点都需要三块逻辑盘：/dev/sdb and /dev/sdc devices 将作为XFS使用
# 准备工作
1、安装支持工具包
yum install -y xfsprogs rsync

2、格式化/dev/sdb and /dev/sdc devices为XFS
#（测试虚拟机需要先添加两块盘，暂用大小100G）
mkfs.xfs /dev/sdb
mkfs.xfs /dev/sdc

3、Create the mount point directory structure:
mkdir -p /srv/node/sdb
mkdir -p /srv/node/sdc

4、Edit the /etc/fstab file and add the following to it:
cat <<'EOF' >> /etc/fstab
/dev/sdb /srv/node/sdb xfs noatime,nodiratime,nobarrier,logbufs=8 0 2
/dev/sdc /srv/node/sdc xfs noatime,nodiratime,nobarrier,logbufs=8 0 2
EOF

5、Mount the devices:
mount /srv/node/sdb
mount /srv/node/sdc

6、Create or edit the /etc/rsyncd.conf file to contain the following:
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
cat <<EOF >> /etc/rsyncd.conf
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = $IP

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

7、Start the rsyncd service and configure it to start when the system boots:
systemctl enable rsyncd.service
systemctl start rsyncd.service

# 安装配置组件
1、Install the packages:
yum install -y openstack-utils openstack-swift-account openstack-swift-container \
  openstack-swift-object

2、Obtain the accounting, container, and object service configuration files from the Object Storage source repository:
curl -o /etc/swift/account-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/account-server.conf-sample?h=stable/ocata
curl -o /etc/swift/container-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/container-server.conf-sample?h=stable/ocata
curl -o /etc/swift/object-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/object-server.conf-sample?h=stable/ocata

3、Edit the /etc/swift/account-server.conf file and complete the following actions:
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
openstack-config --set /etc/swift/account-server.conf DEFAULT bind_ip $IP
openstack-config --set /etc/swift/account-server.conf DEFAULT bind_port 6202
openstack-config --set /etc/swift/account-server.conf DEFAULT user swift
openstack-config --set /etc/swift/account-server.conf DEFAULT swift_dir /etc/swift
openstack-config --set /etc/swift/account-server.conf DEFAULT devices /srv/node
openstack-config --set /etc/swift/account-server.conf DEFAULT mount_check True
openstack-config --set /etc/swift/account-server.conf pipeline:main pipeline "healthcheck recon account-server"
openstack-config --set /etc/swift/account-server.conf filter:recon use egg:swift#recon
openstack-config --set /etc/swift/account-server.conf filter:recon recon_cache_path /var/cache/swift
4、Edit the /etc/swift/container-server.conf file and complete the following actions:
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
openstack-config --set /etc/swift/container-server.conf DEFAULT bind_ip $IP
openstack-config --set /etc/swift/container-server.conf DEFAULT bind_port 6201
openstack-config --set /etc/swift/container-server.conf DEFAULT user swift
openstack-config --set /etc/swift/container-server.conf DEFAULT swift_dir /etc/swift
openstack-config --set /etc/swift/container-server.conf DEFAULT devices /srv/node
openstack-config --set /etc/swift/container-server.conf DEFAULT mount_check True
openstack-config --set /etc/swift/container-server.conf pipeline:main pipeline "healthcheck recon container-server"
openstack-config --set /etc/swift/container-server.conf filter:recon use egg:swift#recon
openstack-config --set /etc/swift/container-server.conf filter:recon recon_cache_path /var/cache/swift
5、Edit the /etc/swift/object-server.conf file and complete the following actions:
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
openstack-config --set /etc/swift/object-server.conf DEFAULT bind_ip $IP
openstack-config --set /etc/swift/object-server.conf DEFAULT bind_port 6200
openstack-config --set /etc/swift/object-server.conf DEFAULT user swift
openstack-config --set /etc/swift/object-server.conf DEFAULT swift_dir /etc/swift
openstack-config --set /etc/swift/object-server.conf DEFAULT devices /srv/node
openstack-config --set /etc/swift/object-server.conf DEFAULT mount_check True
openstack-config --set /etc/swift/object-server.conf pipeline:main pipeline "healthcheck recon object-server"
openstack-config --set /etc/swift/object-server.conf filter:recon use egg:swift#recon
openstack-config --set /etc/swift/object-server.conf filter:recon recon_cache_path /var/cache/swift
openstack-config --set /etc/swift/object-server.conf filter:recon recon_lock_path /var/lock

6、Ensure proper ownership of the mount point directory structure:
chown -R swift:swift /srv/node

7、Create the recon directory and ensure proper ownership of it:
mkdir -p /var/cache/swift
chown -R root:swift /var/cache/swift
chmod -R 775 /var/cache/swift
*********************object节点操作*************************************************************>
<********************controller1节点（swift-proxy节点）操作*************************************************************
# Create and distribute initial rings
# Create account ring
cd /etc/swift/
swift-ring-builder account.builder create 10 3 1
#Add each storage node to the ring:
#swift-ring-builder account.builder \
#  add --region 1 --zone 1 --ip STORAGE_NODE_MANAGEMENT_INTERFACE_IP_ADDRESS --port 6202 \
#  --device DEVICE_NAME --weight DEVICE_WEIGHT
swift-ring-builder account.builder add \
  --region 1 --zone 1 --ip 10.0.0.62 --port 6202 --device sdb --weight 100
swift-ring-builder account.builder add \
  --region 1 --zone 1 --ip 10.0.0.62 --port 6202 --device sdc --weight 100
swift-ring-builder account.builder add \
  --region 1 --zone 2 --ip 10.0.0.63 --port 6202 --device sdb --weight 100
swift-ring-builder account.builder add \
  --region 1 --zone 2 --ip 10.0.0.63 --port 6202 --device sdc --weight 100
#Verify the ring contents:
swift-ring-builder account.builder
#Rebalance the ring:
swift-ring-builder account.builder rebalance

# Create container ring
cd /etc/swift/
swift-ring-builder container.builder create 10 3 1
#Add each storage node to the ring:
# swift-ring-builder container.builder \
#  add --region 1 --zone 1 --ip STORAGE_NODE_MANAGEMENT_INTERFACE_IP_ADDRESS --port 6201 \
#  --device DEVICE_NAME --weight DEVICE_WEIGHT
swift-ring-builder container.builder add \
  --region 1 --zone 1 --ip 10.0.0.62 --port 6201 --device sdb --weight 100
swift-ring-builder container.builder add \
  --region 1 --zone 1 --ip 10.0.0.62 --port 6201 --device sdc --weight 100
swift-ring-builder container.builder add \
  --region 1 --zone 2 --ip 10.0.0.63 --port 6201 --device sdb --weight 100
swift-ring-builder container.builder add \
  --region 1 --zone 2 --ip 10.0.0.63 --port 6201 --device sdc --weight 100
#Verify the ring contents:
swift-ring-builder container.builder
#Rebalance the ring:
swift-ring-builder container.builder rebalance

# Create object ring
cd /etc/swift/
swift-ring-builder object.builder create 10 3 1
#Add each storage node to the ring:
#swift-ring-builder object.builder \
#  add --region 1 --zone 1 --ip STORAGE_NODE_MANAGEMENT_INTERFACE_IP_ADDRESS --port 6200 \
#  --device DEVICE_NAME --weight DEVICE_WEIGHT
swift-ring-builder object.builder add \
  --region 1 --zone 1 --ip 10.0.0.62 --port 6200 --device sdb --weight 100
swift-ring-builder object.builder add \
  --region 1 --zone 1 --ip 10.0.0.62 --port 6200 --device sdc --weight 100
swift-ring-builder object.builder add \
  --region 1 --zone 2 --ip 10.0.0.63 --port 6200 --device sdb --weight 100
swift-ring-builder object.builder add \
  --region 1 --zone 2 --ip 10.0.0.63 --port 6200 --device sdc --weight 100
#Verify the ring contents:
swift-ring-builder object.builder
#Rebalance the ring:
swift-ring-builder object.builder rebalance

# Distribute ring configuration files
# Copy the account.ring.gz, container.ring.gz, and object.ring.gz files 
# to the /etc/swift directory on each storage node and any additional nodes running the proxy service.
scp /etc/swift/.ring.gz root@object1:/etc/swift
scp /etc/swift/.ring.gz root@object2:/etc/swift
*********************controller1节点（swift-proxy节点）操作*************************************************************>
<********************controller1节点（swift-proxy节点）操作*************************************************************
# 完成安装（ (在swift-proxy节点上执行)）
1、Obtain the /etc/swift/swift.conf file from the Object Storage source repository:
curl -o /etc/swift/swift.conf \
  https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=stable/ocata

2、Edit the /etc/swift/swift.conf file and complete the following actions:
HASH_PATH_SUFFIX=`openssl rand -hex 10`
HASH_PATH_PREFIX=`openssl rand -hex 10`
openstack-config --set /etc/swift/swift.conf swift-hash swift_hash_path_suffix $HASH_PATH_SUFFIX
openstack-config --set /etc/swift/swift.conf swift-hash swift_hash_path_prefix $HASH_PATH_PREFIX
openstack-config --set /etc/swift/swift.conf storage-policy:0 name Policy-0
openstack-config --set /etc/swift/swift.conf storage-policy:0 default yes

3、Copy the swift.conf file to the /etc/swift directory on each storage node and any additional nodes running the proxy service.
scp /etc/swift/swift.conf root@object1:/etc/swift
scp /etc/swift/swift.conf root@object2:/etc/swift

4、On all nodes, ensure proper ownership of the configuration directory:
ssh root@controller1 chown -R root:swift /etc/swift
ssh root@object1 chown -R root:swift /etc/swift
ssh root@object2 chown -R root:swift /etc/swift

5、On the controller node and any other nodes running the proxy service, 
start the Object Storage proxy service including its dependencies and configure them to start when the system boots:
#ssh root@controller1 systemctl enable openstack-swift-proxy.service memcached.service
#ssh root@controller1 systemctl restart openstack-swift-proxy.service memcached.service
#ssh root@controller1 systemctl status openstack-swift-proxy.service memcached.service
systemctl enable openstack-swift-proxy.service memcached.service
systemctl restart openstack-swift-proxy.service memcached.service
systemctl status openstack-swift-proxy.service memcached.service

6、On the storage nodes, start the Object Storage services and configure them to start when the system boots:
(object1 and object2 nodes)
systemctl enable openstack-swift-account.service openstack-swift-account-auditor.service \
  openstack-swift-account-reaper.service openstack-swift-account-replicator.service
systemctl restart openstack-swift-account.service openstack-swift-account-auditor.service \
  openstack-swift-account-reaper.service openstack-swift-account-replicator.service
systemctl status openstack-swift-account.service openstack-swift-account-auditor.service \
  openstack-swift-account-reaper.service openstack-swift-account-replicator.service
systemctl enable openstack-swift-container.service \
  openstack-swift-container-auditor.service openstack-swift-container-replicator.service \
  openstack-swift-container-updater.service
systemctl restart openstack-swift-container.service \
  openstack-swift-container-auditor.service openstack-swift-container-replicator.service \
  openstack-swift-container-updater.service
systemctl status openstack-swift-container.service \
  openstack-swift-container-auditor.service openstack-swift-container-replicator.service \
  openstack-swift-container-updater.service
systemctl enable openstack-swift-object.service openstack-swift-object-auditor.service \
  openstack-swift-object-replicator.service openstack-swift-object-updater.service
systemctl restart openstack-swift-object.service openstack-swift-object-auditor.service \
  openstack-swift-object-replicator.service openstack-swift-object-updater.service
systemctl status openstack-swift-object.service openstack-swift-object-auditor.service \
  openstack-swift-object-replicator.service openstack-swift-object-updater.service

*********************controller1节点（swift-proxy节点）操作*************************************************************>
<********************客户端节点操作*************************************************************
# Verify operation of the Object Storage service.
source /root/admin-openrc
#Show the service status:
swift stat
 swift stat
               Account: AUTH_a5ada618d57d4e2ba784b4c93ab03681
            Containers: 0
               Objects: 0
                 Bytes: 0
       X-Put-Timestamp: 1502278035.22930
           X-Timestamp: 1502278035.22930
            X-Trans-Id: txb3345c31a2fd4e92ae3d6-00598af192
          Content-Type: text/plain; charset=utf-8
X-Openstack-Request-Id: txb3345c31a2fd4e92ae3d6-00598af192

#Create container1 container:
openstack container create container1
+---------------------------------------+------------+------------------------------------+
| account                               | container  | x-trans-id                         |
+---------------------------------------+------------+------------------------------------+
| AUTH_a5ada618d57d4e2ba784b4c93ab03681 | container1 | txf96b80a7b79e40efb04eb-00598af1e9 |
+---------------------------------------+------------+------------------------------------+

#Upload a test file to the container1 container:
#openstack object create <container> <FILE>
openstack object create container1 /root/ks-post.log
+-------------------+------------+----------------------------------+
| object            | container  | etag                             |
+-------------------+------------+----------------------------------+
| /root/ks-post.log | container1 | 4d756861e750f718835b05c772c7b05f |
+-------------------+------------+----------------------------------+

#List files in the container1 container:
openstack object list container1
+-------------------+
| Name              |
+-------------------+
| /root/ks-post.log |
+-------------------+

#Download a test file from the container1 container:
#openstack object save <container> <FILE>
openstack object save container1 /root/ks-post.log
openstack object save container1 /root/ks-post.log --file test.txt

*********************客户端节点操作*************************************************************>

####################################################################################################
#
#       安装配置heat
#
####################################################################################################
# Prerequisites
# 1. create database
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE heat;
EOF
# Grant proper access to the heat database:
mysql -uroot -p123456 <<'EOF'
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' \
  IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' \
  IDENTIFIED BY '123456';
EOF
# verify
mysql -Dheat -uheat -p123456 <<'EOF'
quit
EOF


# 2. Source the admin credentials to gain access to admin-only CLI commands:
source /root/admin-openrc

# 3. To create the service credentials
openstack user create --domain default heat --password 123456
openstack role add --project service --user heat admin
# Create the heat and heat-cfn service entities:
openstack service create --name heat \
  --description "Orchestration" orchestration
openstack service create --name heat-cfn \
  --description "Orchestration"  cloudformation

# 4. Create the Orchestration service API endpoints:
openstack endpoint create --region RegionOne \
  orchestration public http://controller1:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  orchestration internal http://controller1:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  orchestration admin http://controller1:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  cloudformation public http://controller1:8000/v1
openstack endpoint create --region RegionOne \
  cloudformation internal http://controller1:8000/v1
openstack endpoint create --region RegionOne \
  cloudformation admin http://controller1:8000/v1

# 5. Orchestration requires additional information in the Identity service to manage stacks. To add this information, complete these steps:
openstack domain create --description "Stack projects and users" heat
openstack user create --domain heat heat_domain_admin --password 123456
openstack role add --domain heat --user-domain heat --user heat_domain_admin admin
openstack role create heat_stack_owner
openstack role add --project demo --user demo heat_stack_owner
openstack role create heat_stack_user

# Install and configure components
# 1. Install the packages:
yum install -y openstack-heat-api openstack-heat-api-cfn \
  openstack-heat-engine

# 2. Edit the /etc/heat/heat.conf file and complete the following actions:
openstack-config --set /etc/heat/heat.conf database connection mysql+pymysql://heat:123456@controller1/heat
openstack-config --set /etc/heat/heat.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/heat/heat.conf DEFAULT heat_metadata_server_url http://controller1:8000
openstack-config --set /etc/heat/heat.conf DEFAULT heat_waitcondition_server_url http://controller1:8000/v1/waitcondition
openstack-config --set /etc/heat/heat.conf DEFAULT stack_domain_admin heat_domain_admin
openstack-config --set /etc/heat/heat.conf DEFAULT stack_domain_admin_password 123456
openstack-config --set /etc/heat/heat.conf DEFAULT stack_user_domain_name heat
openstack-config --set /etc/heat/heat.conf keystone_authtoken auth_uri http://controller1:5000
openstack-config --set /etc/heat/heat.conf keystone_authtoken auth_url http://controller1:35357
openstack-config --set /etc/heat/heat.conf keystone_authtoken memcached_servers controller1:11211
openstack-config --set /etc/heat/heat.conf keystone_authtoken auth_type password
openstack-config --set /etc/heat/heat.conf keystone_authtoken project_domain_name default
openstack-config --set /etc/heat/heat.conf keystone_authtoken user_domain_name default
openstack-config --set /etc/heat/heat.conf keystone_authtoken project_name service
openstack-config --set /etc/heat/heat.conf keystone_authtoken username heat
openstack-config --set /etc/heat/heat.conf keystone_authtoken password 123456
openstack-config --set /etc/heat/heat.conf trustee auth_type password
openstack-config --set /etc/heat/heat.conf trustee auth_url http://controller1:35357
openstack-config --set /etc/heat/heat.conf trustee username heat
openstack-config --set /etc/heat/heat.conf trustee password 123456
openstack-config --set /etc/heat/heat.conf trustee user_domain_name default
openstack-config --set /etc/heat/heat.conf clients_keystone auth_uri http://controller1:35357
openstack-config --set /etc/heat/heat.conf ec2authtoken auth_uri http://controller1:5000

# 3. Populate the Orchestration database:
su -s /bin/sh -c "heat-manage db_sync" heat

# Finalize installation
# Start the Orchestration services and configure them to start when the system boots:
systemctl enable openstack-heat-api.service \
  openstack-heat-api-cfn.service openstack-heat-engine.service
systemctl restart openstack-heat-api.service \
  openstack-heat-api-cfn.service openstack-heat-engine.service
systemctl status openstack-heat-api.service \
  openstack-heat-api-cfn.service openstack-heat-engine.service

# Verify operation
. admin-openrc
 openstack orchestration service list
+-------------------+-------------+--------------------+-------------------+--------+----------------------+--------+
| Hostname          | Binary      | Engine ID          | Host              | Topic  | Updated At           | Status |
+-------------------+-------------+--------------------+-------------------+--------+----------------------+--------+
| controller1.local | heat-engine | 65ccbd1e-d391-4f45 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -a105-dd0f4295523c |                   |        | 000000               |        |
| controller1.local | heat-engine | a8fdea1b-a89f-4503 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -a9c2-3b6dd6220eac |                   |        | 000000               |        |
| controller1.local | heat-engine | 592de611-cf4e-4cc3 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -9233-84b49d819c97 |                   |        | 000000               |        |
| controller1.local | heat-engine | 958de7f8-7d5c-     | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | 477a-8caa-         |                   |        | 000000               |        |
|                   |             | cf80b393c80a       |                   |        |                      |        |
| controller1.local | heat-engine | fc83b2df-494b-4ba3 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -9008-8a0f38f0b809 |                   |        | 000000               |        |
| controller1.local | heat-engine | f7298d74-6b75-4348 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -ba82-1eff13ff3eca |                   |        | 000000               |        |
| controller1.local | heat-engine | e7254e23-d268-41f2 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -b1f7-1b9fb8f7da4a |                   |        | 000000               |        |
| controller1.local | heat-engine | 53fd5263-8c74-4182 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -8b1e-258164bb4632 |                   |        | 000000               |        |
| controller1.local | heat-engine | 491fe700-4116-48e4 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -9630-cc5c87433fbf |                   |        | 000000               |        |
| controller1.local | heat-engine | 3097a637-27f9-4e47 | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -bcf9-ee38de8ce7fe |                   |        | 000000               |        |
| controller1.local | heat-engine | a455ead5-4375      | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -44ae-             |                   |        | 000000               |        |
|                   |             | aad8-5a8d14f50729  |                   |        |                      |        |
| controller1.local | heat-engine | 84aa39c9-e866-4e0b | controller1.local | engine | 2017-08-10T06:21:11. | up     |
|                   |             | -a251-d50491889348 |                   |        | 000000               |        |
+-------------------+-------------+--------------------+-------------------+--------+----------------------+--------+

# Launch an instance
# 1. Create a template
cat <<'EOF' > demo-template.yml
heat_template_version: 2015-10-15
description: Launch a basic instance with CirrOS image using the
             ``m1.tiny`` flavor, ``mykey`` key,  and one network.

parameters:
  NetID:
    type: string
    description: Network ID to use for the instance.

resources:
  server:
    type: OS::Nova::Server
    properties:
      image: cirros-0.3.4-x86_64
      flavor: m1.tiny
      key_name: mykey
      networks:
      - network: { get_param: NetID }

outputs:
  instance_name:
    description: Name of the instance.
    value: { get_attr: [ server, name ] }
  instance_ip:
    description: IP address of the instance.
    value: { get_attr: [ server, first_address ] }
EOF

# 2. Create a stack
. demo-openrc
 openstack network list
+--------------------------------------+-----------+------------------------------------------------------------------+
| ID                                   | Name      | Subnets                                                          |
+--------------------------------------+-----------+------------------------------------------------------------------+
| 2a3770fa-41f4-44aa-a716-3e3fa1d6472b | provider1 | 1ba2efe9-33e8-4577-8160-d0bf447ddb71                             |
| 766b8550-ff25-4987-bdae-f3b0a0affea3 | private1  | d6cfa42d-a856-4013-934f-4db63432ba3b                             |
| cfd68389-89d5-4847-a587-148ac2bb0a9d | private2  | 15dd9c63-6e98-4e05-8db8-d7fa265b9a91, 42ca9efd-                  |
|                                      |           | 2dcf-4356-b491-1ca96f479e8b                                      |
+--------------------------------------+-----------+------------------------------------------------------------------+

# Generate and add a key pair
ssh-keygen -q -N ""
openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey
+-------------+-------------------------------------------------+
| Field       | Value                                           |
+-------------+-------------------------------------------------+
| fingerprint | 98:25:eb:7c:16:a3:c5:b9:5c:ec:48:1b:df:c0:e0:7e |
| name        | mykey                                           |
| user_id     | fbe5750c946445ceaaa0c74f0125c74a                |
+-------------+-------------------------------------------------+
openstack keypair list
+-------+-------------------------------------------------+
| Name  | Fingerprint                                     |
+-------+-------------------------------------------------+
| mykey | 98:25:eb:7c:16:a3:c5:b9:5c:ec:48:1b:df:c0:e0:7e |
+-------+-------------------------------------------------+

# Create a stack of one CirrOS instance on the provider network
export NET_ID=$(openstack network list | awk '/ provider1 / { print $2 }')
echo $NET_ID
openstack stack create -t demo-template.yml --parameter "NetID=$NET_ID" stack
+---------------------+-----------------------------------------------------------------------------------------------+
| Field               | Value                                                                                         |
+---------------------+-----------------------------------------------------------------------------------------------+
| id                  | b63a2144-c118-41dc-a466-58fe2322222e                                                          |
| stack_name          | stack                                                                                         |
| description         | Launch a basic instance with CirrOS image using the ``m1.tiny`` flavor, ``mykey`` key,  and   |
|                     | one network.                                                                                  |
| creation_time       | 2017-08-10T06:42:38Z                                                                          |
| updated_time        | None                                                                                          |
| stack_status        | CREATE_IN_PROGRESS                                                                            |
| stack_status_reason | Stack CREATE started                                                                          |
+---------------------+-----------------------------------------------------------------------------------------------+
openstack stack list
+--------------------------------------+------------+-----------------+----------------------+--------------+
| ID                                   | Stack Name | Stack Status    | Creation Time        | Updated Time |
+--------------------------------------+------------+-----------------+----------------------+--------------+
| b63a2144-c118-41dc-a466-58fe2322222e | stack      | CREATE_COMPLETE | 2017-08-10T06:42:38Z | None         |
+--------------------------------------+------------+-----------------+----------------------+--------------+
 openstack stack output show --all stack
+---------------+-------------------------------------------------+
| Field         | Value                                           |
+---------------+-------------------------------------------------+
| instance_name | {                                               |
|               |   "output_value": "stack-server-oyq65e47c6ql",  |
|               |   "output_key": "instance_name",                |
|               |   "description": "Name of the instance."        |
|               | }                                               |
| instance_ip   | {                                               |
|               |   "output_value": "192.161.17.69",              |
|               |   "output_key": "instance_ip",                  |
|               |   "description": "IP address of the instance."  |
|               | }                                               |
+---------------+-------------------------------------------------+
openstack server list | grep stack
| 9a4f72bd-b518-45b8-a54d-62c37ce748af | stack-server-oyq65e47c6ql | ACTIVE | provider1=192.161.17.69             | cirros-0.3.4-x86_64 |
# ssh login vm server
ssh cirros@192.161.17.69
# Delete the stack.
openstack stack delete --yes stack

####################################################################################################
#
#       安装配置barbican(存在问题：1、python-gunicorn包找不到；2、安装完成后，测试发现api调用不成功)
#
####################################################################################################
# Prerequisites
# 1. To create the database
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE barbican;
GRANT ALL PRIVILEGES ON barbican.* TO 'barbican'@'localhost' \
  IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON barbican.* TO 'barbican'@'%' \
  IDENTIFIED BY '123456';
EOF
# test
mysql -Dbarbican -ubarbican -p123456 <<'EOF'
quit
EOF

# 2. Source the admin credentials to gain access to admin-only CLI commands:
source admin-openrc

# 3. To create the service credentials, complete these steps:
openstack user create --domain default barbican --password 123456
openstack role add --project service --user barbican admin
openstack role create creator
openstack role add --project service --user barbican creator
openstack service create --name barbican --description "Key Manager" key-manager

# 4. Create the Key Manager service API endpoints:
openstack endpoint create --region RegionOne \
  key-manager public http://controller1:9311
openstack endpoint create --region RegionOne \
  key-manager internal http://controller1:9311
openstack endpoint create --region RegionOne \
  key-manager admin http://controller1:9311

# Install and configure components
# 1. Install the packages:（need use internet yum repo）
yum install -y openstack-barbican-api

# 2. Edit the /etc/barbican/barbican.conf file and complete the following actions:
openstack-config --set /etc/barbican/barbican.conf DEFAULT sql_connection mysql+pymysql://barbican:123456@controller1/barbican
openstack-config --set /etc/barbican/barbican.conf DEFAULT transport_url rabbit://openstack:123456@controller1 
openstack-config --set /etc/barbican/barbican.conf DEFAULT host_href http://controller1:9311
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken auth_uri http://controller1:5000 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken auth_url http://controller1:35357 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken memcached_servers controller1:11211 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken auth_type password 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken project_domain_name default 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken user_domain_name default 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken project_name service
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken username barbican 
openstack-config --set /etc/barbican/barbican.conf keystone_authtoken password 123456

# 3. Edit the /etc/barbican/barbican-api-paste.ini file and complete the following actions:
openstack-config --set /etc/barbican/barbican-api-paste.ini pipeline:barbican_api pipeline "cors authtoken context apiapp"

# 4. Populate the Key Manager service database:
#(To prevent The Key Manager service database will be automatically populated when the service is first started)
openstack-config --set /etc/barbican/barbican.conf DEFAULT db_auto_create false
# Then populate the database as below:
su -s /bin/sh -c "barbican-manage db upgrade" barbican

# 5. Barbican has a plugin architecture which allows the deployer to store secrets in a number of different back-end secret stores. By default, Barbican is configured to store secrets in a basic file-based keystore. This key store is NOT safe for production use.
# For a list of supported plugins and detailed instructions on how to configure them, see Secret Store Back-ends


# Finalize installation
# 1. Create the /etc/httpd/conf.d/wsgi-barbican.conf file with the following content:
cat <<'EOF' > /etc/httpd/conf.d/wsgi-barbican.conf
Listen 9311
<VirtualHost *:9311>
    ServerName controller1
    
    ## Logging
    ErrorLog "/var/log/httpd/barbican_wsgi_main_error_ssl.log"
    LogLevel debug
    ServerSignature Off
    CustomLog "/var/log/httpd/barbican_wsgi_main_access_ssl.log" combined

    WSGIApplicationGroup %{GLOBAL}
    WSGIDaemonProcess barbican-api display-name=barbican-api group=barbican processes=2 threads=8 user=barbican
    WSGIProcessGroup barbican-api
    WSGIScriptAlias / "/usr/lib/python2.7/site-packages/barbican/api/app.wsgi"
    WSGIPassAuthorization On
    LimitRequestBody 114688

    <Directory /usr/lib/python2.7/site-packages/barbican/api>
        Options All
        AllowOverride All
        Require all granted
    </Directory>

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF

# 2. Start the Apache HTTP service and configure it to start when the system boots:
systemctl enable httpd.service
systemctl restart httpd.service
systemctl status httpd.service

# Verify operation
# 1. Source the admin credentials to be able to perform Barbican API calls:
. admin-openrc
openstack secret list

# 2. Use the OpenStack CLI to store a secret:
openstack secret store --name mysecret --payload j4=]d21
+---------------+-------------------------------------------------------------------------+
| Field         | Value                                                                   |
+---------------+-------------------------------------------------------------------------+
| Secret href   | http://controller1:9311/v1/secrets/8f8cb437-fdd8-4bba-a3fd-ea3495cd655d |
| Name          | mysecret                                                                |
| Created       | None                                                                    |
| Status        | None                                                                    |
| Content types | None                                                                    |
| Algorithm     | aes                                                                     |
| Bit length    | 256                                                                     |
| Secret type   | opaque                                                                  |
| Mode          | cbc                                                                     |
| Expiration    | None                                                                    |
+---------------+-------------------------------------------------------------------------+

# 3. Confirm that the secret was stored by retrieving it:
openstack secret get http://controller1:9311/v1/secrets/8f8cb437-fdd8-4bba-a3fd-ea3495cd655d
+---------------+-------------------------------------------------------------------------+
| Field         | Value                                                                   |
+---------------+-------------------------------------------------------------------------+
| Secret href   | http://controller1:9311/v1/secrets/8f8cb437-fdd8-4bba-a3fd-ea3495cd655d |
| Name          | mysecret                                                                |
| Created       | 2017-08-15T08:05:59+00:00                                               |
| Status        | ACTIVE                                                                  |
| Content types | {u'default': u'text/plain'}                                             |
| Algorithm     | aes                                                                     |
| Bit length    | 256                                                                     |
| Secret type   | opaque                                                                  |
| Mode          | cbc                                                                     |
| Expiration    | None                                                                    |
+---------------+-------------------------------------------------------------------------+

# 4. Confirm that the secret payload was stored by retrieving it:
openstack secret get http://controller1:9311/v1/secrets/8f8cb437-fdd8-4bba-a3fd-ea3495cd655d --payload
+---------+---------+
| Field   | Value   |
+---------+---------+
| Payload | j4=]d21 |
+---------+---------+

# 5. delete a secret
openstack secret mysecret http://controller1:9311/v1/secrets/8f8cb437-fdd8-4bba-a3fd-ea3495cd655d

####################################################################################################
#
#       安装配置magnum
# 依赖已安装组件: Identity service, Image service, Compute service, Networking service, 
# Block Storage service and Orchestration service. 
#
####################################################################################################
# Prerequisites
# 1. create database
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE magnum;
EOF
# Grant proper access to the magnum database:
mysql -uroot -p123456 <<'EOF'
GRANT ALL PRIVILEGES ON magnum.* TO 'magnum'@'localhost' \
  IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON magnum.* TO 'magnum'@'%' \
  IDENTIFIED BY '123456';
EOF
# verify
mysql -Dmagnum -umagnum -p123456 <<'EOF'
quit
EOF


# 2. Source the admin credentials to gain access to admin-only CLI commands:
source /root/admin-openrc

# 3. To create the service credentials
openstack user create --domain default magnum --password 123456
openstack role add --project service --user magnum admin
openstack service create --name magnum \
  --description "OpenStack Container Infrastructure Management Service" \
  container-infra

# 4. Create the Container Infrastructure Management service API endpoints:
openstack endpoint create --region RegionOne \
  container-infra public http://controller1:9511/v1
openstack endpoint create --region RegionOne \
  container-infra internal http://controller1:9511/v1
openstack endpoint create --region RegionOne \
  container-infra admin http://controller1:9511/v1

# 5. Magnum requires additional information in the Identity service to manage COE clusters. To add this information, complete these steps:
openstack domain create --description "Owns users and projects \
  created by magnum" magnum
openstack user create --domain magnum magnum_domain_admin --password 123456
openstack role add --domain magnum --user-domain magnum --user \
  magnum_domain_admin admin

# Install and configure components¶
# 1. Install the packages:
yum install -y openstack-magnum-api openstack-magnum-conductor python-magnumclient

# 2. Edit the /etc/magnum/magnum.conf file:
NIC=eth0
IP=`LANG=C ip addr show dev $NIC | grep 'inet '| grep $NIC$  |  awk '/inet /{ print $2 }' | awk -F '/' '{ print $1 }'`
openstack-config --set /etc/magnum/magnum.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/magnum/magnum.conf api host 0.0.0.0
openstack-config --set /etc/magnum/magnum.conf database connection mysql+pymysql://magnum:123456@controller1/magnum
# select barbican (or x509keypair if you don’t have barbican installed)
openstack-config --set /etc/magnum/magnum.conf certificates cert_manager_type barbican
openstack-config --set /etc/magnum/magnum.conf cinder_client region_name RegionOne
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken auth_uri http://controller1:5000/v3
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken auth_version v3
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken auth_url http://controller1:35357
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken memcached_servers controller1:11211
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken auth_type password
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken project_domain_id default
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken user_domain_id default
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken project_name service
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken username magnum
openstack-config --set /etc/magnum/magnum.conf keystone_authtoken password 123456
openstack-config --set /etc/magnum/magnum.conf trust trustee_domain_name magnum
openstack-config --set /etc/magnum/magnum.conf trust trustee_domain_admin_name magnum_domain_admin
openstack-config --set /etc/magnum/magnum.conf trust trustee_domain_admin_password 123456
openstack-config --set /etc/magnum/magnum.conf trust trustee_keystone_interface public
openstack-config --set /etc/magnum/magnum.conf trust trustee_domain_id $(openstack domain show magnum | awk '/ id /{print $4}')
openstack-config --set /etc/magnum/magnum.conf trust trustee_domain_admin_id $(openstack user show magnum_domain_admin | awk '/ id /{print $4}')
openstack-config --set /etc/magnum/magnum.conf oslo_messaging_notifications driver messaging
openstack-config --set /etc/magnum/magnum.conf oslo_concurrency lock_path /var/lib/magnum/tmp

# 3. Populate Magnum database:
su -s /bin/sh -c "magnum-db-manage upgrade" magnum

# Finalize installation
systemctl enable openstack-magnum-api.service \
  openstack-magnum-conductor.service
systemctl restart openstack-magnum-api.service \
  openstack-magnum-conductor.service
systemctl status openstack-magnum-api.service \
  openstack-magnum-conductor.service

# fixed bug 1: 无法解析主机名字controller1的问题。
# cause: 配置中多处url使用controller1作为服务地址，该配置在公共dns中无法解释。
# solution1：搭建云服务dns，将controller1 192.161.17.51公共地址作为A记录配置好，容器集群模板将dns server指向该dns服务；
# solution2：修改各个容器节点的/etc/hosts, 添加名字解析条目：
1) 添加文件/usr/lib/python2.7/site-packages/magnum/drivers/common/templates/swarm/fragments/add-host.sh，内容如下：
vi /usr/lib/python2.7/site-packages/magnum/drivers/common/templates/swarm/fragments/add-host.sh
#!/bin/sh

cat <<'EOF' >> /etc/hosts
192.161.17.51 controller1 controller1.local
192.161.17.55 compute1 compute1.local
192.161.17.56 compute2 compute2.local
10.0.0.59 network1 network1.local
10.0.0.60 cinder1 cinder1.local
10.0.0.61 nfs1 nfs1.local
10.0.0.62 object1 object1.local
10.0.0.63 object2 object2.local
EOF

2)修改模板文件
vi /usr/lib/python2.7/site-packages/magnum/drivers/swarm_fedora_atomic_v1/templates/swarmmaster.yaml
在239行插入5行内容
  add_host:
    type: "OS::Heat::SoftwareConfig"
    properties:
      group: ungrouped
      config: {get_file: ../../common/templates/swarm/fragments/add-host.sh}
在372行插入一行内容
  swarm_master_init:
    type: "OS::Heat::MultipartMime"
    properties:
      parts:
        - config: {get_resource: add_host}

vi /usr/lib/python2.7/site-packages/magnum/drivers/swarm_fedora_atomic_v1/templates/swarmnode.yaml
在221行插入5行内容
  add_host:
    type: "OS::Heat::SoftwareConfig"
    properties:
      group: ungrouped
      config: {get_file: ../../common/templates/swarm/fragments/add-host.sh}
在335行插入一行内容
  swarm_master_init:
    type: "OS::Heat::MultipartMime"
    properties:
      parts:
        - config: {get_resource: add_host}

# fixed bug 2: magnum-api: RemoteError: Remote error: BadRequest Invalid input for field 'identity/password/user/password': None is not of type 'string' (HTTP 400) 
# This commit changes how the Nova client is configured to use the
# token_endpoint authentication plugin combined with endpoint_override,
# which allows to communicate with the Nova endpoint without extra
# requests to Keystone. This is necessary between trust-scoped tokens
# cannot re-authenticate with Keystone, which happens with other
# authentication plugins.
# 虚拟机节点初始化报错：KeyError: 'pem'
# 问题状态：该问题未解决，创建集群成功后，节点内的docker服务等启动不起来。
测试程序：
#!/usr/bin/python

from keystoneauth1.identity import v3 as ka_v3
from keystoneauth1 import session as ka_session
from keystoneclient.v3 import client as kc_v3

auth = ka_v3.Password(
    auth_url='http://controller1:5000/v3',
    user_id='4f40e113ab8f4ba38a39e405757999d4',
    domain_id='02989454dec145ac8ad6a0d06f06b16d',
    password='123456')

session = ka_session.Session(auth=auth)
domain_admin_client = kc_v3.Client(session=session)
user = domain_admin_client.users.create(
    name='ares',
    password='123456')

domain_admin_client.users.delete(user)




# Verify operation
# 1. Source the admin tenant credentials:
source admin-openrc

# 2. To list out the health of the internal services, namely conductor, of magnum, use:
magnum service-list
+----+------+------------------+-------+----------+-----------------+---------------------------+---------------------------+
| id | host | binary           | state | disabled | disabled_reason | created_at                | updated_at                |
+----+------+------------------+-------+----------+-----------------+---------------------------+---------------------------+
| 1  | -    | magnum-conductor | up    |          | -               | 2017-08-15T08:18:45+00:00 | 2017-08-15T08:29:58+00:00 |
+----+------+------------------+-------+----------+-----------------+---------------------------+---------------------------+

# Launch an instance
# Create an external network (Optional)
# 1. Create an external network with an appropriate provider based on your cloud provider support for your case:
openstack network create public --provider-network-type vxlan \
      --external \
      --project service

openstack subnet create public-subnet --network public \
      --subnet-range 192.161.14.0/24 \
      --gateway 192.161.14.1 \
      --ip-version 4

# Provision a cluster and create a container
# 1. Download the ocata Fedora Atomic image built by magnum team, which is required to provision the cluster:
wget https://fedorapeople.org/groups/magnum/fedora-atomic-ocata.qcow2

# 2. Source the demo credentials to perform the following steps as a non-administrative project:
source demo-openrc

# 3. Register the image to the Image service setting the os_distro property to fedora-atomic:
openstack image create \
      --disk-format=qcow2 \
      --container-format=bare \
      --file=fedora-atomic-ocata.qcow2 \
      --property os_distro='fedora-atomic' \
      fedora-atomic-ocata
openstack image create \
      --disk-format=qcow2 \
      --container-format=bare \
      --file=ubuntu-mesos-ocata.qcow2 \
      --property os_distro='ubuntu-mesos' \
      ubuntu-mesos-ocata

# 4. Create a keypair on the Compute service:
openstack keypair list
openstack keypair delete mykey
openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey

# 5. Create a cluster template for a Docker Swarm cluster using the above image, m1.small as flavor for the master and the node, mykey as keypair, public as external network and 192.168.1.12 for DNS nameserver, with the following command:
magnum cluster-template-create --name swarm-cluster-template \
     --image fedora-atomic-ocata \
     --keypair mykey \
     --external-network provider1 \
     --fixed-network private1 \
     --fixed-subnet private1-v4-1 \
     --dns-nameserver 192.168.1.12 \
     --master-flavor m1.small \
     --flavor m1.small \
     --coe swarm

# magnum cluster-template-list
# magnum cluster-template-delete  swarm-cluster-template


# 6. Create a cluster with one node and one master with the following command:
magnum cluster-create --name swarm-cluster \
    --cluster-template swarm-cluster-template \
    --master-count 1 \
    --node-count 1 \
    --timeout 120

magnum cluster-create --name swarm-cluster1 \
    --cluster-template swarm-cluster-template \
    --master-count 1 \
    --node-count 1

# cluster-create failed when cert_manager_type = barbican:

# check the status of you cluster using the commands: 
magnum cluster-list 
magnum cluster-show swarm-cluster
magnum cluster-show swarm-cluster1

# 7. Add the credentials of the above cluster to your environment:
# 如果没安装，需要先安装客户端：
pip install --upgrade python-magnumclient
# 执行命令
mkdir myclusterconfig
$(magnum cluster-config swarm-cluster1 --dir myclusterconfig)

# 8. Create a container:
docker run busybox echo "Hello from Docker!"

# 9. Delete the cluster:
# magnum cluster-list 
magnum cluster-delete swarm-cluster
# magnum cluster-template-list
magnum cluster-template-delete swarm-cluster-template

####################################################################################################
#
#       安装配置trove
#
####################################################################################################
# Prerequisites
# 1. create database
mysql -uroot -p123456 <<'EOF'
CREATE DATABASE trove;
EOF
# Grant proper access to the trove database:
mysql -uroot -p123456 <<'EOF'
GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'localhost' \
  IDENTIFIED BY '123456';
GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'%' \
  IDENTIFIED BY '123456';
EOF
# verify
mysql -Dtrove -utrove -p123456 <<'EOF'
quit
EOF


# 2. Source the admin credentials to gain access to admin-only CLI commands:
source /root/admin-openrc

# 3. To create the service credentials
openstack user create --domain default trove --password 123456
openstack role add --project service --user trove admin
openstack service create --name trove \
  --description "Database" \
  database

# 4. Create the Container Infrastructure Management service API endpoints:
openstack endpoint create --region RegionOne \
  database public http://controller1:8779/v1.0/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  database internal http://controller1:8779/v1.0/%\(tenant_id\)s
openstack endpoint create --region RegionOne \
  database admin http://controller1:8779/v1.0/%\(tenant_id\)s

# Install and configure components
# 1. Install the packages:
yum install -y openstack-trove python-troveclient

# 2. In the /etc/trove directory, edit the trove.conf, trove-taskmanager.conf and trove-conductor.conf files and complete the following steps:
# * Provide appropriate values for the following settings:
openstack-config --set /etc/trove/trove.conf DEFAULT log_dir /var/log/trove
openstack-config --set /etc/trove/trove.conf DEFAULT trove_auth_url http://controller1:5000/v2.0
openstack-config --set /etc/trove/trove.conf DEFAULT nova_compute_url http://controller1:8774/v2
openstack-config --set /etc/trove/trove.conf DEFAULT cinder_url http://controller1:8776/v1
openstack-config --set /etc/trove/trove.conf DEFAULT swift_url http://controller1:8080/v1/AUTH_
openstack-config --set /etc/trove/trove.conf DEFAULT notifier_queue_hostname controller1
openstack-config --set /etc/trove/trove.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/trove/trove.conf database connection mysql+pymysql://trove:123456@controller1/trove
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT log_dir /var/log/trove
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT trove_auth_url http://controller1:5000/v2.0
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT nova_compute_url http://controller1:8774/v2
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT cinder_url http://controller1:8776/v1
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT swift_url http://controller1:8080/v1/AUTH_
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT notifier_queue_hostname controller1
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/trove/trove-taskmanager.conf database connection mysql+pymysql://trove:123456@controller1/trove
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT log_dir /var/log/trove
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT trove_auth_url http://controller1:5000/v2.0
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT nova_compute_url http://controller1:8774/v2
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT cinder_url http://controller1:8776/v1
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT swift_url http://controller1:8080/v1/AUTH_
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT notifier_queue_hostname controller1
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT transport_url rabbit://openstack:123456@controller1
openstack-config --set /etc/trove/trove-conductor.conf database connection mysql+pymysql://trove:123456@controller1/trove

# * Configure the Database service to use the RabbitMQ message broker by setting the following options in each file:
openstack-config --set /etc/trove/trove.conf DEFAULT rpc_backend rabbit
openstack-config --set /etc/trove/trove.conf oslo_messaging_rabbit rabbit_host controller1
openstack-config --set /etc/trove/trove.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/trove/trove.conf oslo_messaging_rabbit rabbit_password 123456
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT rpc_backend rabbit
openstack-config --set /etc/trove/trove-taskmanager.conf oslo_messaging_rabbit rabbit_host controller1
openstack-config --set /etc/trove/trove-taskmanager.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/trove/trove-taskmanager.conf oslo_messaging_rabbit rabbit_password 123456
openstack-config --set /etc/trove/trove-conductor.conf DEFAULT rpc_backend rabbit
openstack-config --set /etc/trove/trove-conductor.conf oslo_messaging_rabbit rabbit_host controller1
openstack-config --set /etc/trove/trove-conductor.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/trove/trove-conductor.conf oslo_messaging_rabbit rabbit_password 123456

# 3. Verify that the api-paste.ini file is present in /etc/trove.
ll /etc/trove/api-paste.ini

# 4. Edit the trove.conf file so it includes appropriate values for the settings shown below:
openstack-config --set /etc/trove/trove.conf DEFAULT auth_strategy keystone
# Config option for showing the IP address that nova doles out
openstack-config --set /etc/trove/trove.conf DEFAULT add_addresses True
openstack-config --set /etc/trove/trove.conf DEFAULT network_label_regex ^NETWORK_LABEL$
#openstack-config --set /etc/trove/trove.conf DEFAULT network_label_regex ".*"
openstack-config --set /etc/trove/trove.conf DEFAULT api_paste_config /etc/trove/api-paste.ini
openstack-config --set /etc/trove/trove.conf keystone_authtoken auth_uri http://controller1:5000
openstack-config --set /etc/trove/trove.conf keystone_authtoken auth_url http://controller1:35357
openstack-config --set /etc/trove/trove.conf keystone_authtoken auth_type password
openstack-config --set /etc/trove/trove.conf keystone_authtoken project_domain_name default
openstack-config --set /etc/trove/trove.conf keystone_authtoken user_domain_name default
openstack-config --set /etc/trove/trove.conf keystone_authtoken project_name service
openstack-config --set /etc/trove/trove.conf keystone_authtoken username trove
openstack-config --set /etc/trove/trove.conf keystone_authtoken password 123456

# 5. Edit the trove-taskmanager.conf file 
# Configuration options for talking to nova via the novaclient.
# These options are for an admin user in your keystone config.
# It proxy's the token received from the user to send to nova
# via this admin users creds,
# basically acting like the client via that proxy token.
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT nova_proxy_admin_user admin
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT nova_proxy_admin_pass 123456
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT nova_proxy_admin_tenant_name service
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT taskmanager_manager trove.taskmanager.manager.Manager
# Inject configuration into guest via ConfigDrive
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT use_nova_server_config_drive True
# Set these if using Neutron Networking
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT network_driver trove.network.neutron.NeutronDriver
openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT network_label_regex ".*"

# 6. Edit the /etc/trove/trove-guestagent.conf file so that future trove guests can connect to your OpenStack environment:
wget -O /etc/trove/trove-guestagent.conf \
https://raw.githubusercontent.com/openstack/trove/master/etc/trove/trove-guestagent.conf.sample
openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT rabbit_host controller1
openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT rabbit_password 123456
openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT nova_proxy_admin_user admin
openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT nova_proxy_admin_pass 123456
openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT nova_proxy_admin_tenant_name service
openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT trove_auth_url http://controller1:35357/v2.0
openstack-config --set /etc/trove/trove-guestagent.conf oslo_messaging_rabbit rabbit_host controller1
openstack-config --set /etc/trove/trove-guestagent.conf oslo_messaging_rabbit rabbit_password 123456

# 7. Populate the trove database you created earlier in this procedure:
su -s /bin/sh -c "trove-manage db_sync" trove

# Finalize installation
systemctl enable openstack-trove-api.service \
  openstack-trove-taskmanager.service \
  openstack-trove-conductor.service
systemctl restart openstack-trove-api.service \
  openstack-trove-taskmanager.service \
  openstack-trove-conductor.service
systemctl status openstack-trove-api.service \
  openstack-trove-taskmanager.service \
  openstack-trove-conductor.service

# Install and configure the Trove dashboard
# 1. Installation of the Trove dashboard for Horizon is straightforward. While there packages available for Mitaka, they have a bug which prevents network selection while creating instances. So it is best to install via pip.
yum install -y python-pip
pip install trove-dashboard
pip list | grep trove
# The command above will install the latest version which is appropriate if you are running the latest Trove. If you are running an earlier version of Trove you may need to specify a compatible version of trove-dashboard. 7.0.0.0b2 is known to work with the Mitaka release of Trove.
# 2. After pip installs them locate the trove-dashboard directory and copy the contents of the enabled/ directory to your horizon openstack_dashboard/local/enabled/ directory.
cp /usr/lib/python2.7/site-packages/trove_dashboard/enabled/_*.py \
 /usr/share/openstack-dashboard/openstack_dashboard/enabled/

# Reload apache to pick up the changes to Horizon.
systemctl restart httpd.service memcached.service
systemctl status httpd.service memcached.service


####################################################################################################
#
#       安装配置
#
####################################################################################################

# Start final steps
$SNIPPET('kickstart_done')
# End final steps
%end
