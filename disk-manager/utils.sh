#!/bin/bash

# 单位转换函数：将人类可读的大小转换为 MB
to_mb() {
    local input=$1
    if [[ $input =~ ^([0-9]+(\.[0-9]+)?)\s*([KMGTP]?B?)?$ ]]; then
        local num=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[3],,} # 小写单位
        case "$unit" in
            kb|k) echo $(awk "BEGIN {print int($num / 1024)}");;
            mb|m) echo $(awk "BEGIN {print int($num)}");;
            gb|g) echo $(awk "BEGIN {print int($num * 1024)}");;
            tb|t) echo $(awk "BEGIN {print int($num * 1024 * 1024)}");;
            pb|p) echo $(awk "BEGIN {print int($num * 1024 * 1024 * 1024)}");;
            *) echo $(awk "BEGIN {print int($num)}");;
        esac
    else
        echo "Invalid size format: $input" >&2
        exit 1
    fi
}

# 判断是否为分区
is_partition() {
    local device=$1
    [[ "$device" =~ ^/dev/[a-z]+[0-9]+$ ]]
}

# 判断是否为整块设备
is_whole_device() {
    local device=$1
    [[ "$device" =~ ^/dev/[a-z]+$ ]]
}

# 检查设备是否包含分区表
check_device_partition_table() {
    local device=$1
    partition_table_info=$(fdisk -l "$device" 2>&1)
    if echo "$partition_table_info" | grep -q "doesn't contain a valid partition table"; then
        return 1  # 设备没有分区表
    else
        return 0  # 设备有分区表
    fi
}

# 检查本地磁盘设备的未分配空间
check_unallocated_space() {
    echo "正在检查本地磁盘设备的未分配空间..."

    # 初始化数组
    declare -gA FREE_SPACES  # 使用全局关联数组存储设备及其可用空间
    declare -ga DEVICES      # 使用全局索引数组存储设备列表

    # 清空数组
    FREE_SPACES=()
    DEVICES=()

    # 获取所有块设备信息（包括磁盘和分区）
    devices=$(lsblk -dno NAME,TYPE | awk '$2 == "disk" || $2 == "part" {print "/dev/" $1}')

    # 遍历每个设备
    for device in $devices; do
        echo "检查设备: $device"

        if is_partition "$device"; then
            # 如果是分区，直接获取其大小
            size=$(lsblk -bno SIZE "$device" 2>/dev/null)
            if [ -n "$size" ]; then
                free_space=$(awk "BEGIN {print int($size / 1024 / 1024)}")M
                FREE_SPACES["$device"]=$free_space
                DEVICES+=("$device")
            fi
        else
            # 如果是整块设备，检查未分配空间
            partition_info=$(parted -s "$device" print free 2>/dev/null)
            if echo "$partition_info" | grep -q "Free Space"; then
                free_space=$(echo "$partition_info" | grep "Free Space" | tail -n 1 | awk '{print $3}')
                if [ -z "$free_space" ]; then
                    echo "警告：无法提取设备 $device 的未分配空间大小。"
                    continue
                fi
                FREE_SPACES["$device"]=$free_space
                DEVICES+=("$device")
            fi
        fi
    done

    # 打印调试信息
    echo "DEBUG: FREE_SPACES=(${!FREE_SPACES[@]})"
    for device in "${!FREE_SPACES[@]}"; do
        echo "DEBUG: $device -> ${FREE_SPACES[$device]}"
    done
}
