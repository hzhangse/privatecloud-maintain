#!/bin/bash

# 定义全局变量和配置文件路径
STATE_FILE="./lvm_state.json"
NEW_PARTITION=""  # 用于存储新创建的分区路径
vg_name="vg_thinpool"       # 默认卷组名称前缀
thin_pool_name="thinpool"   # 默认 Thin Pool 名称
do_backup=false # 默认不备份
part_type=30   #代表我机器上的lvm type

# 全局变量
STATE_FILE="./lvm_state.json"
OPERATION=""
selected_device=""

# 加载其他脚本文件
source ./utils.sh
source ./partition.sh
source ./lvm.sh


# 主菜单
main_menu() {
    options=("创建 Thin LVM" "创建分区" "扩展卷组" "扩展逻辑卷" "回退 LVM 操作" "退出")

    PS3="请选择操作： "
    select opt in "${options[@]}"; do
        case $opt in
            "创建 Thin LVM")
                create_thin_lvm
                ;;
            "创建分区")
                create_partition_menu
                ;;
            "扩展卷组")
                extend_vg
                ;;
            "扩展逻辑卷")
                extend_lv
                ;;
            "回退 LVM 操作")
                rollback_lvm
                ;;
            "退出")
                echo "退出脚本。"
                break
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac
    done
}

# 主程序入口
load_state
main_menu
