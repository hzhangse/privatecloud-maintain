(base) ryan@ZBook-G10:~/tools/virtual-proxmox/libvirt$ sudo virsh net-info default
Name:           default
UUID:           0230f067-cec2-4da9-a604-4f4eb72501fe
Active:         yes
Persistent:     yes
Autostart:      yes
Bridge:         virbr0

(base) ryan@ZBook-G10:~/tools/virtual-proxmox/libvirt$ sudo virsh net-dumpxml default
<network connections='3'>
  <name>default</name>
  <uuid>0230f067-cec2-4da9-a604-4f4eb72501fe</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:2b:a3:4c'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>


cat <<EOF > ./my-network.xml
<network>
  <name>my-network</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr1' stp='on' delay='0'/>
  <mac address='52:54:01:2b:a6:4e'/>
  <ip address='193.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='193.168.122.2' end='193.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-define ./my-network.xml

sudo virsh net-list --all
 Name         State      Autostart   Persistent
-------------------------------------------------
 default      active     yes         yes
 my-network   inactive   no          yes



sudo virsh net-autostart my-network 
sudo virsh net-start my-network 

sudo virsh net-destroy my-network 
sudo virsh net-undefine my-network 

