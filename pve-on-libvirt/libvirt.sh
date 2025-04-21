#!/bin/bash


NETWORK_NAME="my-network"       # 网络名称
BRIDGE_NAME="virbr1"            # 网桥名称
MAC_ADDRESS="52:54:01:2b:a6:4e" # MAC 地址
IP_ADDRESS="193.168.122.1"      # IP 地址
NETMASK="255.255.255.0"         # 子网掩码
DHCP_START="193.168.122.2"      # DHCP 起始地址
DHCP_END="193.168.122.254"
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
  if [[ -z "$NETWORK_NAME" || -z "$BRIDGE_NAME" || -z "$MAC_ADDRESS" ||
    -z "$IP_ADDRESS" || -z "$NETMASK" || -z "$DHCP_START" || -z "$DHCP_END" ]]; then
    echo "Usage: $0 <network_name> <bridge_name> <mac_address> <ip_address> <netmask> <dhcp_start> <dhcp_end>"
    exit 1
  fi

  # 创建 XML 文件
  cat <<EOF >"./${NETWORK_NAME}.xml"
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



#定义一个基于 LVM 的存储池
setup_libvirt_storage_pool() {
  virsh pool-define-as $STORAGE_POOL_NAME logical --source-name $VG_NAME --target /dev/$VG_NAME
  virsh pool-start $STORAGE_POOL_NAME
  virsh pool-list --all

}

setup_libvirt_storage_volume() {
  pvenode=$1
  node_name=$(ssh root@$pvenode hostname)
  lv_name=${LV_DISK}_$node_name
  lv_path="/dev/${VG_NAME}/${lv_name}"

  echo "virsh vol-create-as $STORAGE_POOL_NAME $lv_name $LV_SIZE"
  virsh vol-create-as $STORAGE_POOL_NAME $lv_name $LV_SIZE
  virsh vol-list $STORAGE_POOL_NAME

  virsh attach-disk $node_name $lv_path $disk_device --cache none --subdriver raw
}




