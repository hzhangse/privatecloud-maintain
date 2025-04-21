#!/bin/bash

vm_template="ubuntu-noble-template"
vmid=502
vg_disk="vg_$disk_device"
lv_disk="${disk_device}lvm"

build_pve_env() {
  echo "install pve using pve_node ip "
  echo "cp id_rsa.pub "
  echo "add a second disk and assign a think lvm named as vdblvm"
}

setup_vdb_lv() {
  NODE=$1

  # 提取数字部分
  value=$(echo "$LV_SIZE" | grep -o '[0-9]*')

  # 提取数字部分和非数字部分
  value=${LV_SIZE%?}  # 去掉最后一个字符（非数字部分）
  unit=${LV_SIZE: -1} # 提取最后一个字符（单位）

  # 计算 99% 的值
  result=$(echo "$value * 0.99" | bc)

  # 拼接结果和单位
  lv_act_size="${result}${unit}"

  ssh root@$NODE "bash -c '
    pvcreate /dev/$disk_device
    vgcreate $vg_disk /dev/$disk_device

    lvcreate --type thin-pool --size $lv_act_size --name $lv_disk $vg_disk
    pvesm add lvmthin vdblvm --vgname $vg_disk --thinpool $lv_disk
   '"
}

build_image_template() {
  PVE_NODE=$1
  ((vmid++))
  # 将云镜像文件和 SSH 公钥上传到目标 PVE 节点
  scp /home/ryan/tools/virtual-proxmox/noble-server-cloudimg-amd64.img /home/ryan/.ssh/id_rsa.pub root@$PVE_NODE:/root

  # 使用单引号包裹整个远程命令，并使用双引号来允许变量替换
  ssh root@$PVE_NODE "bash -c '
    vmid=$vmid
    vm_template=\"$vm_template\"
    vm_template_id=$vm_template_id

    # 创建虚拟机模板，分配内存、CPU 和网络配置
    qm create \$vmid --name \"\$vm_template\" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26
    
    # 导入云镜像文件并附加为虚拟机的磁盘
    qm importdisk \$vmid /root/noble-server-cloudimg-amd64.img ${lv_disk}
    
    # 设置 Cloud-Init 配置（SCSI2 设备）
    qm set \$vmid --ide2 ${lv_disk}:cloudinit
    
    # 设置 SCSI 磁盘设备（主磁盘）
    qm set \$vmid --scsi0 $lv_disk:vm-\$vmid-disk-0
    
    # 设置 SCSI 控制器类型为 virtio-scsi-pci
    qm set \$vmid --scsihw virtio-scsi-pci
    
    # 设置启动顺序为从 SCSI 磁盘启动
    qm set \$vmid --boot order=scsi0
    
    # 添加 Cloud-Init 配置盘（SCSI1 设备）
    qm set \$vmid --scsi1 $lv_disk:cloudinit
    
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
    partprobe /dev/mapper/${vg_disk}-vm--\$vmid--disk--0

    # 获取云镜像的第一个分区路径
    targetpart=\$(readlink -f /dev/mapper/${vg_disk}-vm--\$vmid--disk--0p1)
    
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





