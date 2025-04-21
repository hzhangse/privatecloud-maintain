#!/bin/bash
NODES=("193.168.122.95")
#NODES=("192.168.122.91" "192.168.122.92" "192.168.122.93" "193.168.122.94")
disk_device="vdb"

VG_NAME="vg_pve"
LV_DISK="lv_$disk_device"
LV_SIZE="20G"

STORAGE_POOL_NAME="PVE_POOL"


source ./libvirt.sh
source ./pve.sh
source ../utils.sh

main() {
# 调用函数，传入参数
  #setup_libvirt_network $my-network $BRIDGE_NAME $MAC_ADDRESS $IP_ADDRESS  $NETMASK $DHCP_START $DHCP_END
  #setup_libvirt_network
  #setup_libvirt_storage_pool
  echo "所有节点的配置已完成！"

  i=0
  # ==============================
  # 主循环：遍历每个节点并调用配置函数
  # ==============================
  for NODE in "${NODES[@]}"; do
    echo "正在配置节点 $NODE..."
    #install_dependencies "$NODE"
    #setup_vdb_lv $NODE
    build_image_template $NODE
    #setup_libvirt_storage_volume $NODE
   
    ((i++))
  done

  echo "所有节点的配置已完成！"

  
}

main
