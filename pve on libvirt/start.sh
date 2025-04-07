#!/bin/bash

PVE_NODE="193.168.122.94"
vm_template="ubuntu_noble_template"
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
    scp /home/ryan/tools/virtual-proxmox/noble-server-cloudimg-amd64.img /home/ryan/.ssh/id_rsa.pub root@$PVE_NODE:/root

    # 在目标 PVE 节点上执行远程命令
    ssh root@$PVE_NODE "bash -c '
        # 创建虚拟机模板，分配内存、CPU 和网络配置
        qm create $vmid \
            --name $vm_template \
            --memory 4096 \
            --cores 2 \
            --net0 virtio,bridge=vmbr0 \
            --ostype l26
        
        # 导入云镜像文件并附加为虚拟机的磁盘
        qm importdisk $vm_template_id /root/noble-server-cloudimg-amd64.img vdblvm    
        
        # 为虚拟机设置 Cloud-Init 配置（IDE2 设备）
        qm set $vm_template_id --ide2 vdblvm:cloudinit
        
        # 导入云镜像作为虚拟机的主磁盘
        qm importdisk $vmid /root/noble-server-cloudimg-amd64.img vdblvm

        # 设置 SCSI 磁盘设备（主磁盘）
        qm set $vmid --scsi0 vdblvm:vm-$vmid-disk-0

        # 设置 SCSI 控制器类型为 virtio-scsi-pci
        qm set $vmid --scsihw virtio-scsi-pci

        # 设置启动顺序为从 SCSI 磁盘启动
        qm set $vmid --boot order=scsi0

        # 添加 Cloud-Init 配置盘（SCSI1 设备）
        qm set $vmid --scsi1 vdblvm:cloudinit

        # 设置 Cloud-Init 的默认用户为 root
        qm set $vmid --ciuser root

        # 设置 Cloud-Init 使用的 SSH 公钥
        qm set $vmid --sshkey /root/id_rsa.pub

        # 设置 Cloud-Init 的默认密码
        qm set $vmid --cipassword passw0rd

        # 禁用自动更新（可选）
        qm set $vmid --ciupgrade 0

        # 配置 DHCP 自动获取 IP 地址（IPv4 和 IPv6）
        qm set $vmid --ipconfig0 ip=dhcp,ip6=dhcp
    '"

    # 更新分区表以识别新磁盘分区
    partprobe /dev/mapper/vdblvm-vm--$vmid--disk--0

    # 获取云镜像的第一个分区路径
    targetpart=$(readlink -f /dev/mapper/vdblvm-vm--$vmid--disk--0p1)

    # 挂载云镜像分区到本地目录
    mkdir -p /home/disk0 && mount $targetpart /home/disk0

    # 创建自定义脚本目录
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
    umount $targetpart
    umount /home/disk0

    # 将虚拟机标记为模板
    qm template $vmid
}




#!/bin/bash

# 定义全局变量
freespace_label="可用空间"

# 检查本地磁盘设备是否有未分配空间的脚本
check_unallocated_space() {
    echo "正在检查本地磁盘设备的未分配空间..."

    # 获取所有块设备信息（排除分区）
    devices=$(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print $1}')

    # 初始化一个空数组，用于存储设备和未分配空间
    declare -A free_spaces

    # 遍历每个磁盘设备
    for device in $devices; do
        echo "检查设备: /dev/$device"

        # 使用 parted 获取设备的分区表和未分配空间
        partition_info=$(parted -s /dev/$device print free 2>/dev/null)

        # 检查是否存在未分配空间
        if echo "$partition_info" | grep -q "$freespace_label"; then
            # 提取未分配空间的大小
            free_space=$(echo "$partition_info" | grep "$freespace_label" | tail -n 1 | awk '{print $3}')
            echo "设备 /dev/$device 存在未分配空间，大小为：$free_space"
            free_spaces["/dev/$device"]=$free_space
        else
            echo "设备 /dev/$device 没有未分配空间。"
        fi

        echo "----------------------------------------"
    done

    # 返回设备和未分配空间的关联数组
    echo "以下设备有未分配空间："
    for dev in "${!free_spaces[@]}"; do
        echo "$dev: ${free_spaces[$dev]}"
    done

    # 将结果导出到全局变量
    export FREE_SPACES=("${free_spaces[@]}")
    export DEVICES=("${!free_spaces[@]}")
}

# 创建 Thin LVM 的函数
create_thin_lvm() {
    # 检查是否检测到未分配空间
    if [ ${#DEVICES[@]} -eq 0 ]; then
        echo "没有检测到任何未分配空间，无法创建 Thin LVM。"
        exit 1
    fi

    # 列出可用设备及其未分配空间
    echo "请选择要使用的设备："
    for i in "${!DEVICES[@]}"; do
        echo "$i: ${DEVICES[$i]} (${FREE_SPACES[$i]})"
    done

    # 让用户选择设备
    read -p "请输入设备编号： " device_index

    # 验证用户输入
    if ! [[ "$device_index" =~ ^[0-9]+$ ]] || [ "$device_index" -ge ${#DEVICES[@]} ]; then
        echo "无效的设备编号。"
        exit 1
    fi

    selected_device=${DEVICES[$device_index]}
    selected_free_space=${FREE_SPACES[$device_index]}

    echo "已选择设备：$selected_device，未分配空间大小：$selected_free_space"

    # 让用户输入 Thin LVM 的大小
    read -p "请输入要创建的 Thin LVM 大小（例如 100G）： " lvm_size

    # 验证输入格式
    if ! [[ "$lvm_size" =~ ^[0-9]+[GgMm]$ ]]; then
        echo "无效的大小格式。请使用类似 '100G' 或 '500M' 的格式。"
        exit 1
    fi

    # 转换大小为字节，方便后续比较
    size_suffix="${lvm_size: -1}"  # 获取单位后缀（G 或 M）
    size_value="${lvm_size%?}"     # 获取数值部分

    case "$size_suffix" in
        G|g) lvm_bytes=$((size_value * 1024 * 1024 * 1024));;
        M|m) lvm_bytes=$((size_value * 1024 * 1024));;
        *) echo "无效的大小单位。"; exit 1;;
    esac

    # 检查请求的大小是否小于等于未分配空间
    free_space_value=$(echo "$selected_free_space" | sed 's/[GM]//')  # 去掉单位
    free_space_suffix=$(echo "$selected_free_space" | grep -o '[GM]')

    case "$free_space_suffix" in
        G) free_space_bytes=$((free_space_value * 1024 * 1024 * 1024));;
        M) free_space_bytes=$((free_space_value * 1024 * 1024));;
        *) echo "未知的未分配空间单位。"; exit 1;;
    esac

    if [ "$lvm_bytes" -gt "$free_space_bytes" ]; then
        echo "请求的大小超出未分配空间范围。"
        exit 1
    fi

    # 创建物理卷
    echo "在设备 $selected_device 上创建物理卷..."
    pvcreate "$selected_device"

    # 创建卷组
    vg_name="vg_thinpool"
    echo "创建卷组 $vg_name..."
    vgcreate "$vg_name" "$selected_device"

    # 创建 Thin Pool
    thin_pool_name="thinpool"
    echo "在卷组 $vg_name 中创建 Thin Pool $thin_pool_name，大小为 $lvm_size..."
    lvcreate --type thin-pool --size "$lvm_size" --name "$thin_pool_name" "$vg_name"

    echo "Thin LVM 创建完成！"
}

# 主程序入口
check_unallocated_space
create_thin_lvm



#build_image_template
# 调用函数，传入参数
#setup_libvirt_network $my-network $BRIDGE_NAME $MAC_ADDRESS $IP_ADDRESS  $NETMASK $DHCP_START $DHCP_END

























