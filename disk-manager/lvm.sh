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

    # 列出所有设备及其状态（包括已被占用的设备）
    echo "请选择要使用的设备或分区："
    index=0
    declare -gA DEVICE_INDEX_MAP # 用于映射编号到设备路径

    # 显示所有设备（包括未分配空间的设备和已被占用的设备）
    for device in "${!FREE_SPACES[@]}" "${!VG_OCCUPIED[@]}"; do
        if [ -n "${FREE_SPACES[$device]}" ]; then
            # 可选设备
            echo "$index: $device (${FREE_SPACES[$device]})"
            DEVICE_INDEX_MAP["$index"]="$device"
            index=$((index + 1))
        elif [ -n "${VG_OCCUPIED[$device]}" ]; then
            # 已被占用的设备或分区
            echo "  * $device (已被卷组 ${VG_OCCUPIED[$device]} 占用，不可选)"
        fi
    done

    # 用户选择设备
    while true; do
        read -p "请输入设备编号： " device_index

        if [ -z "$device_index" ]; then
            echo "输入不能为空，请输入有效的设备编号。"
        elif ! [[ "$device_index" =~ ^[0-9]+$ ]] || [ -z "${DEVICE_INDEX_MAP[$device_index]}" ]; then
            echo "无效的设备编号，请重新输入。"
        else
            selected_device=${DEVICE_INDEX_MAP[$device_index]}
            selected_free_space=${FREE_SPACES["$selected_device"]}
            break
        fi
    done

    echo "已选择设备：$selected_device，可用空间大小：$selected_free_space"

    # 检查是否为整块设备
    if is_whole_device "$selected_device"; then
        echo "$selected_device 是整块设备，将为其创建分区..."

        # 用户输入分区大小
        while true; do
            read -p "请输入新分区的大小（例如 100M 或 1G）： " partition_size

            if [[ "$partition_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
                create_partition "$selected_device" "$partition_size"
                # 获取最新分区路径
                new_partition=$(get_latest_partition "$selected_device")
                if [ $? -ne 0 ]; then
                    echo "错误：无法获取设备 $device 的最新分区路径。"
                    return 1
                fi

                #new_partition=$(create_partition "$selected_device" "$partition_size")
                # 使用最新分区路径
                selected_device=$new_partition
                selected_free_space=$partition_size
                FREE_SPACES["$new_partition"]=$selected_free_space
                DEVICES+=("$new_partition")
                #echo "selected_device: $selected_device selected_free_space: $selected_free_space"
                break
            else
                echo "无效的分区大小格式，请重新输入。"
            fi
        done

    fi

    # 用户输入卷组名称
    read -p "请输入 Volume Group 名称（留空使用默认名称 vg_$(date +%s)）：" vg_name
    if [ -z "$vg_name" ]; then
        vg_name="vg_$(date +%s)"
    fi

    # 用户输入 Thin Pool 大小
    while true; do
        read -p "请输入 Thin Pool 的大小（例如 100M）： " thin_pool_size

        if [[ "$thin_pool_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
            # 检查设备大小是否足够

            thin_pool_mb=$(to_mb "$thin_pool_size")
            free_space_mb=$(to_mb "$selected_free_space")

            if ((thin_pool_mb <= free_space_mb)); then
                break
            else
                echo "错误：请求的 Thin Pool 大小 $thin_pool_size ($thin_pool_mb MB) 超过了设备 $selected_device 的可用空间大小 $selected_free_space ($free_space_mb MB)。"
                echo "请重新输入 Thin Pool 大小。"
            fi

        else
            echo "无效的 Thin Pool 大小格式，请重新输入。"
        fi
    done

    # 调用创建 Thin LVM 的函数
    create_thin_lvm_on_device "$selected_device" "$vg_name" "$thin_pool_size"

    echo "Thin LVM 创建完成！"
}

# 在指定设备上创建 Thin LVM
create_thin_lvm_on_device() {
    local device=$1
    local vg_name=$2
    local thin_pool_size=$3
    echo "$device"
    # 将 Thin Pool 大小转换为 MB
    thin_pool_mb=$(to_mb "$thin_pool_size")

    # 检查设备的可用空间是否足够
    # echo ":-----FREE_SPACES   ------"
    # index=0
    # for device in "${!FREE_SPACES[@]}"; do
    #     echo "$index: $device (${FREE_SPACES[$device]})"
    #     index=$((index + 1))
    # done

    free_space_size=${FREE_SPACES["$device"]}
    free_space_mb=$(to_mb "$free_space_size")
    if ((thin_pool_mb > free_space_mb)); then
        echo "错误：请求的 Thin Pool 大小 $thin_pool_size ($thin_pool_mb MB) 超过了设备 $device 的可用空间大小 $free_space_size ($free_space_mb MB)。"
        echo "请重新选择设备或调整 Thin Pool 大小。"
        return 1
    fi

    echo "正在设备 $device 上创建 Thin LVM..."

    # 创建物理卷
    pvcreate "$device"
    if [ $? -ne 0 ]; then
        echo "创建物理卷失败！"
        exit 1
    fi

    # 创建卷组
    vgcreate "$vg_name" "$device"
    if [ $? -ne 0 ]; then
        echo "创建卷组失败！"
        exit 1
    fi

    # 创建 Thin Pool
    let actual_pool_size=thin_pool_mb-20
    lvcreate --type thin-pool -L "${actual_pool_size}M" -n ${vg_name}_thin_pool "${vg_name}"
    if [ $? -ne 0 ]; then
        echo "创建 Thin Pool 失败！"
        exit 1
    fi

    echo "Thin LVM 创建成功！"

    # 设置当前操作类型并保存状态
    OPERATION="create_thin_lvm"
    save_state

    # 回显创建结果
    display_lvm_status "$vg_name"
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

    # 设置当前操作类型并保存状态
    OPERATION="extend_vg"
    vg_name="$selected_vg"
    #save_state
    export extended_vg="$selected_vg" 
    export extended_vg_size="${FREE_SPACES["$selected_device"]}"   
    
}

extend_lv() {

    # 调用 extend_vg 并捕获输出
    extend_vg
   
    if [ -z "$extended_vg" ] || [ -z "$extended_vg_size" ]; then
        echo "扩展卷组失败，无法继续扩展逻辑卷。$extended_vg $extended_vg_size "
        return
    fi
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
    while read -r lv_name vg_name; do
        if [[ "$vg_name" == "$extended_vg" ]]; then
            echo "${#lv_list[@]}: $vg_name/$lv_name"
            lv_list+=("$vg_name/$lv_name")
        fi
    done < <(echo "$lvs")

    # 检查是否有符合条件的逻辑卷
    if ((${#lv_list[@]} == 0)); then
        echo "没有找到属于卷组 '$select_vg_name' 的逻辑卷。"
        return
    elif ((${#lv_list[@]} == 1)); then
        # 如果只有一个逻辑卷，自动选择它
        selected_lv=${lv_list[0]}
        echo "已自动选择唯一的逻辑卷：$selected_lv"
    else
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
    fi

    # 检查是否为 Thin Pool
    
    lv_type=$(lvs --noheadings -o segtype "$selected_lv" 2>/dev/null | tr -d ' ')

    # 提炼公共逻辑到函数
    extend_common_logic() {
        local lv_path="$1"
        local lv_type="$2"
        local new_size=$3

        # 获取当前大小
        current_size=$(lvs --noheadings -o lv_size "$lv_path" | awk '{print $1}')
        echo "当前大小：$current_size"

        # 提示用户输入新的大小或选择自动分配
        # while true; do
        #     read -p "请输入新的逻辑卷大小（例如 200M）： " new_size
        #
        #     if [[ "$new_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
        #         break
        #     else
        #         echo "无效的大小格式，请重新输入。"
        #     fi
        # done

        # 扩展逻辑卷
        echo "lvextend -L +$new_size $lv_path"
        lvextend -L "+$new_size" "$lv_path"
        if [ $? -ne 0 ]; then
            echo "扩展逻辑卷失败！"
            exit 1
        fi

        # 文件系统扩展（仅适用于普通逻辑卷）
        if [ "$lv_type" != "thin-pool" ]; then
            fs_type=$(blkid -s TYPE -o value "$(lvdisplay -c "$lv_path" | awk -F ':' '{print $1}')")
            case "$fs_type" in
            ext4 | ext3 | ext2)
                resize2fs "$(lvdisplay -c "$lv_path" | awk -F ':' '{print $1}')"
                ;;
            xfs)
                xfs_growfs "$(lvdisplay -c "$lv_path" | awk -F ':' '{print $1}')"
                ;;
            *)
                echo "不支持的文件系统类型：$fs_type"
                exit 1
                ;;
            esac
        fi

        echo "逻辑卷扩展成功！"
    }

    # 根据逻辑卷类型调用公共逻辑
    if [ "$lv_type" == "thin-pool" ]; then
        echo "检测到 Thin Pool，正在扩展其大小..."
        extend_common_logic "$selected_lv" "thin-pool" $extended_vg_size
    else
        echo "检测到普通逻辑卷，正在扩展其大小..."
        extend_common_logic "$selected_lv" "normal"  $extended_vg_size
    fi

    # 设置当前操作类型并保存状态
    OPERATION="extend_lv"
    save_state $OPERATION $selected_device $extended_vg $selected_lv

}

# 回退 LVM 操作
rollback_lvm() {
    load_state

    # 列出所有未被删除的操作
    echo "请选择要回退的操作："
    index=0
    declare -gA OPERATION_INDEX_MAP # 用于映射编号到记录索引
    while IFS= read -r record; do
        operation=$(echo "$record" | jq -r '.operation')
        device=$(echo "$record" | jq -r '.device')
        vg_name=$(echo "$record" | jq -r '.vg_name')
        lv_name=$(echo "$record" | jq -r '.lv_name')

        echo "$index: 操作类型=$operation, 设备=$device, 卷组=$vg_name, 逻辑卷=$lv_name"
        OPERATION_INDEX_MAP["$index"]="$record"
        index=$((index + 1))
    done <<<"$STATE_RECORDS"

    # 如果没有可用的操作
    if [ $index -eq 0 ]; then
        echo "没有可回退的操作。"
        return
    fi

    # 用户选择操作
    while true; do
        read -p "请输入操作编号： " op_index

        if ! [[ "$op_index" =~ ^[0-9]+$ ]] || [ -z "${OPERATION_INDEX_MAP[$op_index]}" ]; then
            echo "无效的操作编号，请重新输入。"
        else
            selected_record=${OPERATION_INDEX_MAP[$op_index]}
            break
        fi
    done

    # 解析选中的记录
    operation=$(echo "$selected_record" | jq -r '.operation')
    device=$(echo "$selected_record" | jq -r '.device')
    vg_name=$(echo "$selected_record" | jq -r '.vg_name')
    lv_name=$(echo "$selected_record" | jq -r '.lv_name')

    # 执行回退操作
    case "$operation" in
    create_thin_lvm)
        echo "正在回退 Thin LVM 创建操作..."

        lvremove -f "$vg_name/$lv_name"
        vgremove -f "$vg_name"
        pvremove -f "$device"
        # 新增：删除分区
        remove_partitions "$device"
        ;;
    extend_vg)
        echo "正在回退卷组扩展操作..."
        vgreduce "$vg_name" "$device"
        pvremove $device

        ;;
    extend_lv)
        echo "正在回退逻辑卷扩展操作..."
        vgreduce "$vg_name" "$device"
        pvremove $device
        current_size=$(lvs --noheadings -o lv_size "$vg_name/$lv_name" | awk '{print $1}')
        lvreduce -L "$current_size" "$vg_name/$lv_name"
        ;;
    *)
        echo "未知操作类型：$operation"
        exit 1
        ;;
    esac

    # 更新状态文件，标记为已删除
    jq --argjson record "$selected_record" 'map(if . == $record then .is_deleted = true else . end)' "$STATE_FILE" >"${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "回退操作完成！"
}
