#!/bin/bash

# 创建 Thin LVM
create_thin_lvm() {
    echo "正在创建 Thin LVM..."

    # 调用 check_unallocated_space 函数获取所有设备及其未分配空间
    check_unallocated_space

    # 如果没有可用设备，直接退出
    if [ ${#DEVICES[@]} -eq 0 ]; then
        echo "没有检测到任何可用设备或分区，无法创建 Thin LVM。"
        return
    fi

    # 列出可用设备及其未分配空间，包括分区
    echo "请选择要使用的设备或分区："
    for i in "${!DEVICES[@]}"; do
        device=${DEVICES[$i]}
        free_space=${FREE_SPACES["$device"]}
        echo "$i: $device ($free_space)"
    done

    # 用户选择设备
    while true; do
        read -p "请输入设备编号： " device_index

        if ! [[ "$device_index" =~ ^[0-9]+$ ]] || [ "$device_index" -ge ${#DEVICES[@]} ]; then
            echo "无效的设备编号，请重新输入。"
        else
            break
        fi
    done

    selected_device=${DEVICES[$device_index]}
    selected_free_space=${FREE_SPACES["$selected_device"]}

    echo "已选择设备：$selected_device，可用空间大小：$selected_free_space"

    # 用户输入 Thin Pool 大小
    while true; do
        read -p "请输入 Thin Pool 的大小（例如 100M）： " thin_pool_size

        if [[ "$thin_pool_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
            break
        else
            echo "无效的 Thin Pool 大小格式，请重新输入。"
        fi
    done

    # 调用创建 Thin LVM 的函数
    create_thin_lvm_on_device "$selected_device" "$thin_pool_size"

    echo "Thin LVM 创建完成！"
}

# 在指定设备上创建 Thin LVM
create_thin_lvm_on_device() {
    local device=$1
    local thin_pool_size=$2

    # 将 Thin Pool 大小转换为 MB
    thin_pool_mb=$(to_mb "$thin_pool_size")

    # 检查设备的可用空间是否足够
    free_space_size=${FREE_SPACES["$device"]}
    free_space_mb=$(to_mb "$free_space_size")
    if (( thin_pool_mb > free_space_mb )); then
        echo "错误：请求的 Thin Pool 大小 $thin_pool_size ($thin_pool_mb MB) 超过了设备 $device 的可用空间大小 $free_space_size ($free_space_mb MB)。"
        exit 1
    fi

    echo "正在设备 $device 上创建 Thin LVM..."

    # 创建物理卷
    pvcreate "$device"
    if [ $? -ne 0 ]; then
        echo "创建物理卷失败！"
        exit 1
    fi

    # 创建卷组
    vg_name="vg_$(date +%s)"
    vgcreate "$vg_name" "$device"
    if [ $? -ne 0 ]; then
        echo "创建卷组失败！"
        exit 1
    fi

    # 创建 Thin Pool
    lvcreate --type thin-pool -L "$thin_pool_size" -n thin_pool "$vg_name"
    if [ $? -ne 0 ]; then
        echo "创建 Thin Pool 失败！"
        exit 1
    fi

    echo "Thin LVM 创建成功！"
    echo "卷组名称：$vg_name"
    echo "Thin Pool 名称：thin_pool"
}

# 扩展卷组功能
extend_vg() {
    echo "正在扩展卷组..."

    # 获取所有可用设备及其未分配空间
    check_unallocated_space

    if [ ${#DEVICES[@]} -eq 0 ]; then
        echo "没有检测到任何可用设备或分区，无法扩展卷组。"
        return
    fi

    # 列出可用设备及其未分配空间
    echo "请选择要添加到卷组的设备或分区："
    for i in "${!DEVICES[@]}"; do
        device=${DEVICES[$i]}
        free_space=${FREE_SPACES["$device"]}
        echo "$i: $device ($free_space)"
    done

    # 用户选择设备
    while true; do
        read -p "请输入设备编号： " device_index

        if ! [[ "$device_index" =~ ^[0-9]+$ ]] || [ "$device_index" -ge ${#DEVICES[@]} ]; then
            echo "无效的设备编号，请重新输入。"
        else
            break
        fi
    done

    selected_device=${DEVICES[$device_index]}
    echo "已选择设备：$selected_device"

    # 获取现有卷组列表
    vgs=$(vgs --noheadings -o vg_name)
    if [ -z "$vgs" ]; then
        echo "没有检测到任何现有卷组，无法扩展卷组。"
        return
    fi

    # 列出现有卷组
    echo "请选择要扩展的卷组："
    vg_list=()
    for vg in $vgs; do
        echo "${#vg_list[@]}: $vg"
        vg_list+=("$vg")
    done

    # 用户选择卷组
    while true; do
        read -p "请输入卷组编号： " vg_index

        if ! [[ "$vg_index" =~ ^[0-9]+$ ]] || [ "$vg_index" -ge ${#vg_list[@]} ]; then
            echo "无效的卷组编号，请重新输入。"
        else
            break
        fi
    done

    selected_vg=${vg_list[$vg_index]}
    echo "已选择卷组：$selected_vg"

    # 扩展卷组
    echo "正在将设备 $selected_device 添加到卷组 $selected_vg..."
    vgextend "$selected_vg" "$selected_device"
    if [ $? -ne 0 ]; then
        echo "扩展卷组失败！"
        exit 1
    fi

    echo "卷组扩展成功！"
}

# 扩展逻辑卷功能
extend_lv() {
    echo "正在扩展逻辑卷..."

    # 获取现有逻辑卷列表
    lvs=$(lvs --noheadings -o lv_name,vg_name)
    if [ -z "$lvs" ]; then
        echo "没有检测到任何现有逻辑卷，无法扩展逻辑卷。"
        return
    fi

    # 列出现有逻辑卷
    echo "请选择要扩展的逻辑卷："
    lv_list=()
    for lv_info in $lvs; do
        lv_name=$(echo "$lv_info" | awk '{print $1}')
        vg_name=$(echo "$lv_info" | awk '{print $2}')
        echo "${#lv_list[@]}: $vg_name/$lv_name"
        lv_list+=("$vg_name/$lv_name")
    done

    # 用户选择逻辑卷
    while true; do
        read -p "请输入逻辑卷编号： " lv_index

        if ! [[ "$lv_index" =~ ^[0-9]+$ ]] || [ "$lv_index" -ge ${#lv_list[@]} ]; then
            echo "无效的逻辑卷编号，请重新输入。"
        else
            break
        fi
    done

    selected_lv=${lv_list[$lv_index]}
    echo "已选择逻辑卷：$selected_lv"

    # 检查是否为 Thin Pool
    lv_type=$(lvs --noheadings -o segtype "$selected_lv" 2>/dev/null)
    if [ "$lv_type" == "thin-pool" ]; then
        echo "检测到 Thin Pool，正在扩展其大小..."

        # 获取 Thin Pool 当前大小
        current_size=$(lvs --noheadings -o lv_size "$selected_lv" | awk '{print $1}')
        echo "当前大小：$current_size"

        # 用户输入新的大小
        while true; do
            read -p "请输入新的 Thin Pool 大小（例如 200M）： " new_size

            if [[ "$new_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
                break
            else
                echo "无效的大小格式，请重新输入。"
            fi
        done

        # 扩展 Thin Pool
        lvextend -L "$new_size" "$selected_lv"
        if [ $? -ne 0 ]; then
            echo "扩展 Thin Pool 失败！"
            exit 1
        fi

        echo "Thin Pool 扩展成功！"
    else
        echo "检测到普通逻辑卷，正在扩展其大小..."

        # 获取逻辑卷当前大小
        current_size=$(lvs --noheadings -o lv_size "$selected_lv" | awk '{print $1}')
        echo "当前大小：$current_size"

        # 用户输入新的大小
        while true; do
            read -p "请输入新的逻辑卷大小（例如 200M）： " new_size

            if [[ "$new_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
                break
            else
                echo "无效的大小格式，请重新输入。"
            fi
        done

        # 扩展逻辑卷
        lvextend -L "$new_size" "$selected_lv"
        if [ $? -ne 0 ]; then
            echo "扩展逻辑卷失败！"
            exit 1
        fi

        # 文件系统扩展
        fs_type=$(blkid -s TYPE -o value "$(lvdisplay -c "$selected_lv" | awk -F ':' '{print $1}')")
        case "$fs_type" in
            ext4|ext3|ext2)
                resize2fs "$(lvdisplay -c "$selected_lv" | awk -F ':' '{print $1}')"
                ;;
            xfs)
                xfs_growfs "$(lvdisplay -c "$selected_lv" | awk -F ':' '{print $1}')"
                ;;
            *)
                echo "不支持的文件系统类型：$fs_type"
                exit 1
                ;;
        esac

        echo "逻辑卷扩展成功！"
    fi
}

# 回退 LVM 操作
rollback_lvm() {
    echo "正在回退 LVM 操作..."

    # 获取现有逻辑卷列表
    lvs=$(lvs --noheadings -o lv_name,vg_name)
    if [ -z "$lvs" ]; then
        echo "没有检测到任何现有逻辑卷，无法回退操作。"
        return
    fi

    # 列出现有逻辑卷
    echo "请选择要删除的逻辑卷："
    lv_list=()
    for lv_info in $lvs; do
        lv_name=$(echo "$lv_info" | awk '{print $1}')
        vg_name=$(echo "$lv_info" | awk '{print $2}')
        echo "${#lv_list[@]}: $vg_name/$lv_name"
        lv_list+=("$vg_name/$lv_name")
    done

    # 用户选择逻辑卷
    while true; do
        read -p "请输入逻辑卷编号： " lv_index

        if ! [[ "$lv_index" =~ ^[0-9]+$ ]] || [ "$lv_index" -ge ${#lv_list[@]} ]; then
            echo "无效的逻辑卷编号，请重新输入。"
        else
            break
        fi
    done

    selected_lv=${lv_list[$lv_index]}
    echo "已选择逻辑卷：$selected_lv"

    # 删除逻辑卷
    echo "正在删除逻辑卷 $selected_lv..."
    lvremove -f "$selected_lv"
    if [ $? -ne 0 ]; then
        echo "删除逻辑卷失败！"
        exit 1
    fi

    echo "逻辑卷删除成功！"
}

# 回退操作：删除 LVM、卷组、物理卷及分区
rollback() {
    echo "开始回退操作，删除所有创建的资源..."

    # 删除逻辑卷
    lvs=$(lvs --noheadings -o lv_name,vg_name)
    for lv_info in $lvs; do
        lv_name=$(echo "$lv_info" | awk '{print $1}')
        vg_name=$(echo "$lv_info" | awk '{print $2}')
        lvremove -f /dev/$vg_name/$lv_name
        echo "已删除逻辑卷 $vg_name/$lv_name。"
    done

    # 删除卷组
    vgs=$(vgs --noheadings -o vg_name)
    for vg in $vgs; do
        vgremove -f $vg
        echo "已删除卷组 $vg。"
    done

    # 删除物理卷
    pvs=$(pvs --noheadings -o pv_name)
    for pv in $pvs; do
        pvremove -f $pv
        echo "已删除物理卷 $pv。"
    done

    echo "回退操作完成，所有资源已清理。"
}
