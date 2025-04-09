#!/bin/bash

PVE_NODE="193.168.122.94"
vm_template="ubuntu-noble-template"
vmid=500


NETWORK_NAME="my-network" # 网络名称
BRIDGE_NAME="virbr1"      # 网桥名称
MAC_ADDRESS="52:54:01:2b:a6:4e"  # MAC 地址
IP_ADDRESS="193.168.122.1"       # IP 地址
NETMASK="255.255.255.0"          # 子网掩码
DHCP_START="193.168.122.2"       # DHCP 起始地址
DHCP_END="193.168.122.254"

#


#!/bin/bash

# 定义函数，接受参数
setup_libvirt_network() {
    # 参数解析
    NETWORK_NAME=$1
    BRIDGE_NAME=$2
    MAC_ADDRESS=$3
    IP_ADDRESS=$4
    NETMASK=$5
    DHCP_START=$6
    DHCP_END=$7

    # 检查参数是否完整
    if [[ -z "$NETWORK_NAME" || -z "$BRIDGE_NAME" || -z "$MAC_ADDRESS" || \
          -z "$IP_ADDRESS" || -z "$NETMASK" || -z "$DHCP_START" || -z "$DHCP_END" ]]; then
        echo "Usage: $0 <network_name> <bridge_name> <mac_address> <ip_address> <netmask> <dhcp_start> <dhcp_end>"
        exit 1
    fi

    # 创建 XML 文件
    cat <<EOF > "./${NETWORK_NAME}.xml"
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <mac address='${MAC_ADDRESS}'/>
  <ip address='${IP_ADDRESS}' netmask='${NETMASK}'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF

    # 定义、启动并设置自动启动网络
    sudo virsh net-define "./${NETWORK_NAME}.xml"
    sudo virsh net-autostart "${NETWORK_NAME}"
    sudo virsh net-start "${NETWORK_NAME}"

    # 列出所有网络以确认
    sudo virsh net-list --all
}


build_pve_env(){
  echo "install pve using pve_node ip "
  echo "cp id_rsa.pub "
  echo "add a second disk and assign a think lvm named as vdblvm"
}



build_image_template() {
    # 将云镜像文件和 SSH 公钥上传到目标 PVE 节点
   # scp /home/ryan/tools/virtual-proxmox/noble-server-cloudimg-amd64.img /home/ryan/.ssh/id_rsa.pub root@$PVE_NODE:/root

# 使用单引号包裹整个远程命令，并使用双引号来允许变量替换
ssh root@$PVE_NODE "bash -c '
    vmid=$vmid
    vm_template=\"$vm_template\"
    vm_template_id=$vm_template_id

    # 创建虚拟机模板，分配内存、CPU 和网络配置
    qm create \$vmid --name \"\$vm_template\" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26
    
    # 导入云镜像文件并附加为虚拟机的磁盘
    qm importdisk \$vmid /root/noble-server-cloudimg-amd64.img vdblvm
    
    # 设置 Cloud-Init 配置（SCSI2 设备）
    qm set \$vmid --ide2 vdblvm:cloudinit
    
    # 设置 SCSI 磁盘设备（主磁盘）
    qm set \$vmid --scsi0 vdblvm:vm-\$vmid-disk-0
    
    # 设置 SCSI 控制器类型为 virtio-scsi-pci
    qm set \$vmid --scsihw virtio-scsi-pci
    
    # 设置启动顺序为从 SCSI 磁盘启动
    qm set \$vmid --boot order=scsi0
    
    # 添加 Cloud-Init 配置盘（SCSI1 设备）
    qm set \$vmid --scsi1 vdblvm:cloudinit
    
    # 设置 Cloud-Init 的默认用户为 root
    qm set \$vmid --ciuser root
    
    # 设置 Cloud-Init 使用的 SSH 公钥
    qm set \$vmid --sshkey /root/id_rsa.pub
    
    # 设置 Cloud-Init 的默认密码
    qm set \$vmid --cipassword passw0rd
    
    # 禁用自动更新（可选）
    qm set \$vmid --ciupgrade 0
    
    # 配置 DHCP 自动获取 IP 地址（IPv4 和 IPv6）
    qm set \$vmid --ipconfig0 ip=dhcp,ip6=dhcp

    # 更新分区表以识别新磁盘分区
    partprobe /dev/mapper/vdblvm-vm--\$vmid--disk--0

    # 获取云镜像的第一个分区路径
    targetpart=\$(readlink -f /dev/mapper/vdblvm-vm--\$vmid--disk--0p1)
    
    mkdir -p /home/disk0 && mount \$targetpart /home/disk0
    mkdir -p /home/disk0/var/lib/cloud/scripts/per-instance
    # 编写自定义脚本，在虚拟机首次启动时执行
    cat << EOF > /home/disk0/var/lib/cloud/scripts/per-instance/per-instance.sh
#!/bin/bash
# 删除旧的机器 ID 并重新生成
rm -rf /etc/machine-id && systemd-machine-id-setup

# 更新系统包并安装 net-tools 工具
apt-get update && apt-get install -y net-tools
EOF
    # 赋予脚本可执行权限
    chmod a+x /home/disk0/var/lib/cloud/scripts/per-instance/per-instance.sh

    # 卸载挂载的分区
    umount \home/disk0 && umount \$targetpart
    
    # 将虚拟机标记为模板,需要重啓主機後才能成功執行rename，否則提示磁盤被佔用,但其实也没关系，只是磁盘的名字还维持原样而已
    #qm template \$vmid

'" 


}






build_image_template
# 调用函数，传入参数
#setup_libvirt_network $my-network $BRIDGE_NAME $MAC_ADDRESS $IP_ADDRESS  $NETMASK $DHCP_START $DHCP_END

























