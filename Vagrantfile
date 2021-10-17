# -*- mode: ruby -*-
# vi: set ft=ruby :

servers=[
  {
    :hostname => "coa-lab",
    :box => "generic/ubuntu1604",
    :ram => 16384,
    :cpu => `nproc`.chomp,
    :script => "bash /vagrant/setup.sh"
  }
]
# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.
Vagrant.configure("2") do |config|
  servers.each do |machine|
    config.vm.synced_folder ".", "/vagrant"
    config.vm.box_check_update = false
    config.vm.define machine[:hostname] do |node|
      node.vm.box = machine[:box]
      node.vm.hostname = machine[:hostname]
      node.vm.network "forwarded_port", guest: 80, host: 8080
      node.vm.network "forwarded_port", guest: 6080, host: 6080
      node.vm.provision "shell", inline: machine[:script], privileged: true, run: "once"

      node.vm.provider "virtualbox" do |vb|
#        vb.gui = true
        vb.customize ["modifyvm", :id, "--memory", machine[:ram], "--cpus", machine[:cpu]]
        vb.customize ["modifyvm", :id, "--nic2", "natnetwork", "--nat-network2", "ProviderNetwork", "--nicpromisc2", "allow-all"]
        controller_name = 'SCSI'
        file_to_disk = File.realpath( "." ).to_s + '/openstack_data.vdi'
        vb.customize ['createhd', '--filename', file_to_disk, '--size', 50 * 1024, '--format', 'VDI']
        vb.customize ['storageattach', :id, '--storagectl', controller_name, '--type', 'hdd', '--port', 2, '--medium', file_to_disk]
      end

      node.vm.provider "libvirt" do |libvirt, vm|
        libvirt.cpu_mode = "host-passthrough"
        libvirt.nested = true
        libvirt.cpus = machine[:cpu]
        libvirt.memory = machine[:ram]
        #libvirt.video_type = "qxl"
        libvirt.graphics_type = "vnc"

        libvirt.management_network_name = "os-management"
        libvirt.management_network_address = "10.0.0.0/24"
        libvirt.management_network_guest_ipv6 = "no"
        libvirt.management_network_autostart = "true"
        vm.vm.network :private_network,
          :libvirt__network_name => "os-internal",
          :libvirt__network_address => "10.10.10.0/24",
          :libvirt__host_ip => "10.10.10.1",
          :libvirt__dhcp_start => "10.10.10.2",
          :libvirt__dhcp_stop => "10.10.10.254",
          :libvirt__guest_ipv6 => "no",
          :libvirt__forward_mode => "none",
          :autostart => "true"
        vm.vm.network :private_network,
          :libvirt__network_name => "os-provider",
          :libvirt__network_address => "203.0.113.0/24",
          :libvirt__host_ip => "203.0.113.1",
          :libvirt__dhcp_start => "203.0.113.2",
          :libvirt__dhcp_stop => "203.0.113.254",
          :libvirt__guest_ipv6 => "no",
          :libvirt__forward_mode => "none",
          :autostart => "true"

        libvirt.disk_device = "sda"
        libvirt.disk_bus = "scsi"
        libvirt.storage :file, :size => '50G', :bus => 'scsi'
      end
    end
  end
end
