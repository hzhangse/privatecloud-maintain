#!/bin/bash

# 单位转换函数：将人类可读的大小转换为 MB
to_mb() {
    local input=$1
    if [[ $input =~ ^([0-9]+(\.[0-9]+)?)\s*([KMGTP]?B?)?$ ]]; then
        local num=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[3],,} # 小写单位
        case "$unit" in
        kb | k) echo $(awk "BEGIN {print int($num / 1024)}") ;;
        mb | m) echo $(awk "BEGIN {print int($num)}") ;;
        gb | g) echo $(awk "BEGIN {print int($num * 1024)}") ;;
        tb | t) echo $(awk "BEGIN {print int($num * 1024 * 1024)}") ;;
        pb | p) echo $(awk "BEGIN {print int($num * 1024 * 1024 * 1024)}") ;;
        *) echo $(awk "BEGIN {print int($num)}") ;;
        esac
    else
        echo "Invalid size format: $input" >&2
        exit 1
    fi
}

# 判断是否为分区
is_partition() {
    local device=$1
    [[ "$device" =~ ^/dev/(sd[a-z][0-9]*|vd[a-z][0-9]*|nvme[0-9]+n[0-9]+)p[0-9]+$ ]]
}

# 判断是否为整块设备
is_whole_device() {
    local device=$1
    [[ "$device" =~ ^/dev/(sd[a-z][0-9]*|vd[a-z][0-9]*|nvme[0-9]+n[0-9]+)$ ]]
}

# 检查设备是否包含分区表
check_device_partition_table() {
    local device=$1
    partition_table_info=$(fdisk -l "$device" 2>&1)
    if echo "$partition_table_info" | grep -q "doesn't contain a valid partition table"; then
        return 1 # 设备没有分区表
    else
        return 0 # 设备有分区表
    fi
}

# 检查本地磁盘设备的未分配空间
check_unallocated_space() {
    echo "正在检查本地磁盘设备的未分配空间..."

    # 初始化数组
    declare -gA FREE_SPACES # 使用全局关联数组存储设备及其可用空间
    declare -ga DEVICES     # 使用全局索引数组存储可选设备列表
    declare -gA VG_OCCUPIED # 使用全局关联数组存储设备或分区被哪个卷组占用

    # 清空数组
    FREE_SPACES=()
    DEVICES=()
    VG_OCCUPIED=()

    # 获取所有块设备信息（包括磁盘）
    devices=$(ls /sys/block | grep -E '^vd|^sd|^nvme' | awk '{print "/dev/" $0}')

    # 获取 pvs 输出
    pv_info=$(pvs --noheadings --units g --separator ' ' --nosuffix -o pv_name,vg_name 2>/dev/null)

    # 遍历每个设备
    for device in $devices; do
        echo "检查设备: $device"

        # 检查设备是否已被卷组占用
        while IFS=' ' read -r pv vg; do
            if [[ "$pv" == "$device"* ]]; then
                VG_OCCUPIED["$pv"]="$vg"
            fi
        done <<<"$pv_info"

        if is_whole_device "$device"; then
            # 如果是整块设备，检查未分配空间
            partition_info=$(parted -s "$device" print free 2>/dev/null)
             echo "$partition_info" 
            if echo "$partition_info" | grep  "Free Space"; then
                free_space=$(echo "$partition_info" | grep "Free Space" | tail -n 1 | awk '{print $3}')
                if [ -z "$free_space" ]; then
                    echo "警告：无法提取设备 $device 的未分配空间大小。"
                    continue
                fi
		echo $free_space
                # 将未分配空间添加到 FREE_SPACES 和 DEVICES
                FREE_SPACES["$device"]=$free_space
                DEVICES+=("$device")
            fi

            # 检查该设备是否有分区
            partitions=$(fdisk -l "$device" 2>/dev/null | grep -E '^/dev/')
            while read -r partition_line; do
                if [[ -n "$partition_line" ]]; then
                    partition_dev=$(echo "$partition_line" | awk '{print $1 }')
                    partition_size=$(echo "$partition_line" | awk '{print $5 }')

                    # 检查分区是否已被卷组占用
                    while IFS=' ' read -r pv vg; do
                        if [[ "$pv" == "$partition_dev"* ]]; then
                            VG_OCCUPIED["$partition_dev"]="$vg"
                            continue 2 # 跳出当前循环，继续下一个分区
                        fi
                    done <<<"$pv_info"

                    # 如果分区未被占用，标记为可用
                    if [[ -z "${VG_OCCUPIED[$partition_dev]}" ]]; then
                        FREE_SPACES["$partition_dev"]=$partition_size
                        DEVICES+=("$partition_dev")
                    fi
                fi
            done <<<"$(echo "$partitions")"
        fi
    done

    # 如果没有可用设备，直接退出
    if [ ${#DEVICES[@]} -eq 0 ]; then
        echo "没有检测到任何未分配空间的设备，无法继续操作。"
        exit 1
    fi
}

# 加载上次操作的状态
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        echo "加载上次操作的状态..."
        STATE_RECORDS=$(jq -c '.[] | select(.is_deleted == false)' "$STATE_FILE")
    else
        echo "未找到状态文件，使用默认配置。"
        STATE_RECORDS="[]"
    fi
}

# 保存当前操作的状态
save_state() {
    echo "保存当前操作的状态到 JSON 文件..."
        local OPERATION="$1"
        local selected_device="$2"
        local selected_vg=$3
        local selected_lv=$4
    # 构造新记录
    new_record=$(
        cat <<EOF
{
    "operation": "$OPERATION",
    "device": "$selected_device",
    "vg_name": "$selected_vg",
    "lv_name": "${selected_lv}",
    "is_deleted": false
}
EOF
    )

    # 如果文件不存在，初始化为空数组
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "[]" >"$STATE_FILE"
    fi

    # 将新记录追加到数组中
    jq --argjson record "$new_record" '. += [$record]' "$STATE_FILE" >"${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "状态已保存：$new_record"
}



# 删除指定 PV 对应的分区（使用 fdisk）
remove_partitions() {
    local device=$1

    # 检查是否为整块设备
    if is_whole_device "$device"; then
        echo "错误：$device 是整块设备，无法直接删除其分区。请明确指定要删除的分区。"
        return 1
    fi

    echo "正在删除设备 $device 对应的分区..."

    # 获取设备所属的磁盘
    disk=$(lsblk -no pkname "$device" 2>/dev/null)
    if [ -z "$disk" ]; then
        echo "无法确定设备 $device 所属的磁盘。"
        return 1
    fi
    disk="/dev/$disk"

    # 获取分区编号
    partition_number=$(echo "$device" | grep -oE '[0-9]+$')
    if [ -z "$partition_number" ]; then
        echo "无法解析设备 $device 的分区编号。"
        return 1
    fi

    # 使用 fdisk 删除分区
    #echo "正在从磁盘 $disk 中删除分区 $partition_number..."
    (
        echo d                   # 删除分区
        echo "$partition_number" # 指定分区编号
        echo w                   # 写入更改并退出
    ) | stdbuf -oL fdisk "$disk" >/dev/null 2>&1
    
    partprobe "$disk"
    if [ $? -eq 0 ]; then
        echo "分区 $device 已成功删除。"
    else
        echo "删除分区失败，请检查设备状态。"
        return 1
    fi
}

# 显示 LVM 状态
display_lvm_status() {
    local vg_name=$1

    echo "=========== 创建结果 ==========="
    echo "卷组名称：$vg_name"

    # 显示卷组信息
    echo "卷组详细信息："
    vgs "$vg_name" --units m

    # 显示逻辑卷信息
    echo "逻辑卷详细信息："
    lvs "$vg_name" --units m

    # 显示 Thin Pool 信息
    echo "Thin Pool 详细信息："
    lvs --noheadings -o lv_name,lv_size,segtype "$vg_name" | grep thin-pool | awk '{print "名称: "$1", 大小: "$2", 类型: "$3}'
    echo "================================"
}

# 获取设备或分区的大小（以人类可读的格式返回）
get_device_size() {
    local device=$1

    # 检查设备是否存在
    if [ ! -b "$device" ]; then
        echo "错误：设备 $device 不存在或不是块设备。" >&2
        return 1
    fi

    # 使用 lsblk 获取设备大小（以字节为单位）
    size=$(lsblk -bno SIZE "$device" 2>/dev/null)
    if [ -z "$size" ]; then
        echo "错误：无法获取设备 $device 的大小，请检查设备状态。" >&2
        return 1
    fi

    # 将大小从字节转换为 MB（便于后续计算）
    size_mb=$((size / 1024 / 1024))

    echo "${size_mb}M"
}

# 获取设备的最新分区路径
get_latest_partition() {
    local device=$1
    # 刷新分区表
    partprobe "$device"
    # 使用 lsblk 列出设备的所有分区
    partitions=$(lsblk -lno NAME "$device" 2>/dev/null | grep -v "^$device\$")
    if [ -z "$partitions" ]; then
        echo "错误：设备 $device 没有可用分区。"
        return 1
    fi

    # 获取最后一个分区（即最新创建的分区）
    latest_partition=$(echo "$partitions" | tail -n 1)
    full_path="/dev/$latest_partition"

    # 等待设备路径生成
    wait_for_device "$full_path"
    # 输出设备的最新分区表信息
    echo "$full_path"
}

# 等待设备路径生成
wait_for_device() {
    local device=$1
    local timeout=10 # 最大等待时间（秒）
    local elapsed=0

    while [ ! -b "$device" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ $elapsed -ge $timeout ]; then
            echo "错误：设备 $device 在 $timeout 秒内未能生成，请检查系统配置。"
            return 1
        fi
    done

    #echo "设备 $device 已生成。"
}
