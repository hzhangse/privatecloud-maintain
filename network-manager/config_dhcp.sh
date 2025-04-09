#!/bin/bash



# ==============================
# 提取子网地址段
# ==============================
extract_ip_range() {
    local CIDR=$1
    # 使用 ipcalc 提取网络地址和广播地址
    local NETWORK=$(ipcalc -n "$CIDR" | grep Network | awk '{print $2}')
    local BROADCAST=$(ipcalc -b "$CIDR" | grep Broadcast | awk '{print $2}')
    # 将网络地址和广播地址转换为可用的 IP 起始和结束地址
    echo "${NETWORK%.*}.4 ${BROADCAST%.*}.254"
}

ip_to_int() {
    IFS='.' read -r i1 i2 i3 i4 <<< "$1"
    echo $(( (i1 << 24) | (i2 << 16) | (i3 << 8) | i4 ))
}


# ==============================
# 计算当前节点的 IP 地址范围
# ==============================
calculate_ip_range() {
    local CIDR=$1
    local INDEX=$2
    local TOTAL_NODES=$3

    # 提取子网地址段
    read CIDR_START_IP CIDR_END_IP < <(extract_ip_range "$CIDR")

    # 将起始和结束 IP 转换为数字形式
    START_IP_NUM=$(ip_to_int "$CIDR_START_IP")
    END_IP_NUM=$(ip_to_int "$CIDR_END_IP")
    
    # 总 IP 数量和每个节点的基础 IP 数量
    TOTAL_IPS=$((END_IP_NUM - START_IP_NUM + 1))
    BASE_IPS_PER_NODE=$((TOTAL_IPS / TOTAL_NODES))
    REMAINING_IPS=$((TOTAL_IPS % TOTAL_NODES))
    
    # 动态分配 IP 范围
    if [ "$INDEX" -le "$REMAINING_IPS" ]; then
        # 前几个节点多分配一个 IP 地址
        IPS_PER_NODE=$((BASE_IPS_PER_NODE + 1))
    else
        # 其他节点分配基础数量
        IPS_PER_NODE=$BASE_IPS_PER_NODE
    fi

    # 计算当前节点的起始和结束 IP
    NODE_START_IP_NUM=$((START_IP_NUM + (INDEX - 1) * BASE_IPS_PER_NODE + (INDEX - 1 > REMAINING_IPS ? REMAINING_IPS : (INDEX - 1))))
    NODE_END_IP_NUM=$((NODE_START_IP_NUM + IPS_PER_NODE - 1))

    # 防止越界
    if [ "$NODE_END_IP_NUM" -gt "$END_IP_NUM" ]; then
        NODE_END_IP_NUM=$END_IP_NUM
    fi

    # 转换回点分十进制格式
    NODE_START_IP=$(printf "%d.%d.%d.%d" $((NODE_START_IP_NUM >> 24 & 0xFF)) $((NODE_START_IP_NUM >> 16 & 0xFF)) $((NODE_START_IP_NUM >> 8 & 0xFF)) $((NODE_START_IP_NUM & 0xFF)))
    NODE_END_IP=$(printf "%d.%d.%d.%d" $((NODE_END_IP_NUM >> 24 & 0xFF)) $((NODE_END_IP_NUM >> 16 & 0xFF)) $((NODE_END_IP_NUM >> 8 & 0xFF)) $((NODE_END_IP_NUM & 0xFF)))

    # 输出结果
    echo "$NODE_START_IP $NODE_END_IP"
}

# ==============================
# 封装函数：配置单个 CIDR 的 DHCP
# ==============================
configure_dhcp_for_cidr() {
    local NODE=$1
    local CIDR=$2
    local GATEWAY=$3
    local INTERFACE=$4
    local TOTAL_NODES=$5

    #calculate_ip_range "$CIDR" $i $TOTAL_NODES
    read NODE_START_IP NODE_END_IP < <(calculate_ip_range "$CIDR" $i $TOTAL_NODES)
    echo "Node DHCP Start IP: $NODE_START_IP, Node DHCP End IP: $NODE_END_IP"
    # 写入 DHCP 配置
    ssh root@$NODE "cat <<EOF | tee -a /etc/dnsmasq.conf > /dev/null

# ${INTERFACE} DHCP 配置
interface=${INTERFACE}
#dhcp-range=${INTERFACE},${NODE_START_IP},${NODE_END_IP},255.255.255.0,8h
#dhcp-option=${INTERFACE},option:router,$GATEWAY
#dhcp-option=${INTERFACE},option:dns-server,$GATEWAY

dhcp-option=${INTERFACE},1,255.255.255.0   # 子网掩码
dhcp-option=${INTERFACE},3,$GATEWAY     # 网关
dhcp-option=${INTERFACE},6,$GATEWAY    # DNS服务器
dhcp-range=${INTERFACE},${NODE_START_IP},${NODE_END_IP},255.255.255.0,86400  # 地址范围和租约时间
EOF"
}


# ==============================
# 封装函数：配置 DHCP Failover
# ==============================
configure_dhcp_failover() {
    local NODE=$1
    local OUTPUT_FILE="/etc/dnsmasq.conf"

# 使用 SSH 远程清空文件内容并写入头部信息
    ssh root@$NODE "cat <<EOF | tee $OUTPUT_FILE > /dev/null
# 动态生成的 DHCP 配置
# Node: $NODE
strict-order
except-interface=lo
bind-dynamic
dhcp-no-override
#listen-address=$VIRTUAL_IP  # 绑定到虚拟 IP 地址
dhcp-leasefile=/var/lib/misc/dnsmasq.leases  # 持久化租约文件
EOF"
    # 检查 VLAN_CIDRS 是否为空或仅包含空格
    if [[ -n "${VLAN_CIDRS[@]}" && "${VLAN_CIDRS[@]}" =~ [^[:space:]] ]]; then
        # 配置 VLAN 的 DHCP
        local VLAN_INDEX=10
        for VLAN_CIDR in "${VLAN_CIDRS[@]}"; do
            # 跳过空值或仅包含空格的 CIDR
            if [[ -z "$VLAN_CIDR" || "$VLAN_CIDR" =~ ^[[:space:]]+$ ]]; then
                continue
            fi

            local VLAN_GATEWAY=$(get_gateway_ip "$VLAN_CIDR" "$i")
            local VLAN_TAG=$((VLAN_TAG_BASE + VLAN_INDEX))
            
            local VLAN_INTERFACE=${VLAN_OVS_BRIDGE}_${VLAN_TAG}
            
            if [[ "$VLAN_MODE" == "ovs" ]]; then
                VLAN_INTERFACE=${VLAN_OVS_BRIDGE}_${VLAN_TAG}
    	    elif [[ "$VLAN_MODE" == "iproute2" ]]; then
                VLAN_INTERFACE=${VLAN_iproute2_BRIDGE}_${VLAN_TAG}      
    	    fi
            
            configure_dhcp_for_cidr "$NODE" "$VLAN_CIDR" "$VLAN_GATEWAY" "${VLAN_INTERFACE}"  "${#NODES[@]}"
            ((VLAN_INDEX += 10))
        done
    fi

    # 检查 VXLAN_CIDRS 是否为空或仅包含空格
    if [[ -n "${VXLAN_CIDRS[@]}" && "${VXLAN_CIDRS[@]}" =~ [^[:space:]] ]]; then
        # 配置 VXLAN 的 DHCP
        local VXLAN_INDEX=10
        for VXLAN_CIDR in "${VXLAN_CIDRS[@]}"; do
            # 跳过空值或仅包含空格的 CIDR
            if [[ -z "$VXLAN_CIDR" || "$VXLAN_CIDR" =~ ^[[:space:]]+$ ]]; then
                continue
            fi

            local VXLAN_GATEWAY=$(get_gateway_ip "$VXLAN_CIDR" "$i")
            configure_dhcp_for_cidr "$NODE" "$VXLAN_CIDR" "$VXLAN_GATEWAY" "br_vxlan" "$VXLAN_INDEX" "${#NODES[@]}"
            ((VXLAN_INDEX += 10))
        done
    fi

    # 重启 dnsmasq 服务
    ssh root@$NODE "systemctl restart dnsmasq"

    # 输出调试信息
    echo "DHCP 配置已成功写入远程节点 $NODE 的 $OUTPUT_FILE 文件，并已重启 dnsmasq 服务。"
}


