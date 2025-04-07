#!/bin/bash

# 定义全局变量和配置文件路径
STATE_FILE="./lvm_state.json"
NEW_PARTITION=""  # 用于存储新创建的分区路径
vg_name="vg_thinpool"       # 默认卷组名称前缀
thin_pool_name="thinpool"   # 默认 Thin Pool 名称
do_backup=false # 默认不备份

# 加载其他脚本文件
source ./utils.sh
source ./partition.sh
source ./lvm.sh

# 加载上次操作的状态
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        echo "加载上次操作的状态..."
        source "$STATE_FILE"
    else
        echo "未找到状态文件，使用默认配置。"
    fi
}

# 保存当前操作的状态
save_state() {
    echo "保存当前操作的状态到 JSON 文件..."
    cat <<EOF > "$STATE_FILE"
NEW_PARTITION=$NEW_PARTITION
vg_name=$vg_name
thin_pool_name=$thin_pool_name
IS_DELETED=$IS_DELETED
EOF
}

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
