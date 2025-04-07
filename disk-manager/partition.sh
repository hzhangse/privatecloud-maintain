#!/bin/bash

# 创建新分区
create_partition() {
    local device=$1
    local size=$2

    # 找到设备对应的未分配空间大小（以 MB 为单位）
    free_space_size=${FREE_SPACES["$device"]}
    free_space_mb=$(to_mb "$free_space_size")
    if [ -z "$free_space_mb" ]; then
        echo "错误：无法找到设备 $device 的未分配空间信息。"
        exit 1
    fi

    # 将用户输入的分区大小转换为 MB
    requested_size_mb=$(to_mb "$size")

    # 检查请求的分区大小是否超过未分配空间
    if (( requested_size_mb > free_space_mb )); then
        echo "错误：请求的分区大小 ${size} (${requested_size_mb} MB) 超过了设备 $device 的未分配空间大小 ${free_space_size} (${free_space_mb} MB)。"
        exit 1
    fi

    echo "正在创建新分区..."

    # 使用 fdisk 创建新分区
    (
        echo n     # 新建分区
        echo       # Partition type (default primary)
        echo       # Partition number (default next available)
        echo       # First sector (default start of free space)
        echo "+$size"  # Size (用户指定的大小)
        echo t     # Change partition type
        echo       # Select partition (default last created)
        echo 8e    # Set type to LVM
        echo w     # Write to 分区表
    ) | fdisk "$device"

    if [ $? -ne 0 ]; then
        echo "创建分区失败！"
        exit 1
    fi

    # 刷新分区表
    partprobe "$device"

    # 输出设备的最新分区表信息
    echo "新分区创建成功！以下是设备 $device 的最新分区表信息："
    fdisk -l "$device"

    echo "分区创建完成！"
}

# 主菜单级别的创建分区功能
create_partition_menu() {
    check_unallocated_space

    # 如果没有未分配空间，直接退出
    if [ ${#DEVICES[@]} -eq 0 ]; then
        echo "没有检测到任何未分配空间，无法创建分区。"
        return
    fi

    # 列出可用设备及其未分配空间
    echo "请选择要使用的设备："
    for i in "${!DEVICES[@]}"; do
        device=${DEVICES[$i]}
        free_space=${FREE_SPACES["$device"]}
        echo "$i: $device ($free_space)"
    done

    # 让用户选择设备
    while true; do
        read -p "请输入设备编号： " device_index

        # 验证用户输入
        if ! [[ "$device_index" =~ ^[0-9]+$ ]] || [ "$device_index" -ge ${#DEVICES[@]} ]; then
            echo "无效的设备编号，请重新输入。"
        else
            break
        fi
    done

    selected_device=${DEVICES[$device_index]}
    selected_free_space=${FREE_SPACES["$selected_device"]}

    echo "已选择设备：$selected_device，未分配空间大小：$selected_free_space"

    # 检查设备是否包含分区表
    if check_device_partition_table "$selected_device"; then
        echo "警告：设备 $selected_device 已包含分区表。"
        echo "警告：直接使用该设备可能会导致现有数据丢失！"
        echo "建议：在设备上创建新分区以避免数据丢失。"
        
        # 引导用户创建新分区
        while true; do
            read -p "是否需要创建新分区？(y/n): " choice
            case $choice in
                y|Y)
                    # 让用户输入分区大小
                    while true; do
                        read -p "请输入分区大小（例如 100M）： " partition_size

                        # 验证用户输入的大小格式
                        if [[ "$partition_size" =~ ^[0-9]+[KMGTP]?$ ]]; then
                            break
                        else
                            echo "无效的分区大小格式，请重新输入。"
                        fi
                    done

                    # 调用创建分区函数
                    create_partition "$selected_device" "$partition_size"
                    break
                    ;;
                n|N)
                    echo "继续使用设备 $selected_device 创建 LVM。"
                    break
                    ;;
                *)
                    echo "无效选项，请输入 y 或 n。"
                    ;;
            esac
        done
    else
        echo "设备 $selected_device 当前没有分区表，可以安全地创建新分区或直接使用整个设备。"
    fi
}
