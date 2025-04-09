#!/bin/bash



# ==============================
# 封装函数：配置单个 CIDR 的 DHCP
# ==============================
configure_dhcp_for_cidr() {
    local NODE=$1
    local CIDR=$2
    local GATEWAY=$3
    local INTERFACE_PREFIX=$4
    local INDEX=$5
    local TOTAL_NODES=$6

    # 提取子网地址段
    read CIDR_START_IP CIDR_END_IP < <(extract_ip_range "$CIDR")

    # 计算当前节点的 IP 地址范围
    START_IP_NUM=$(echo "$CIDR_START_IP" | awk -F. '{printf("%d", ($1*256^3)+($2*256^2)+($3*256)+$4)}')
    END_IP_NUM=$(echo "$CIDR_END_IP" | awk -F. '{printf("%d", ($1*256^3)+($2*256^2)+($3*256)+$4)}')
    TOTAL_IPS=$((END_IP_NUM - START_IP_NUM + 1))
    IPS_PER_NODE=$((TOTAL_IPS / TOTAL_NODES))

    # 动态计算当前节点的起始和结束 IP
    NODE_START_IP_NUM=$((START_IP_NUM + (INDEX - 1) * IPS_PER_NODE))
    if [ "$INDEX" -eq "$TOTAL_NODES" ]; then
        # 最后一个节点可能需要处理剩余的 IP 地址
        NODE_END_IP_NUM=$END_IP_NUM
    else
        NODE_END_IP_NUM=$((NODE_START_IP_NUM + IPS_PER_NODE - 1))
    fi

    NODE_START_IP=$(printf "%d.%d.%d.%d" $((NODE_START_IP_NUM >> 24 & 0xFF)) $((NODE_START_IP_NUM >> 16 & 0xFF)) $((NODE_START_IP_NUM >> 8 & 0xFF)) $((NODE_START_IP_NUM & 0xFF)))
    NODE_END_IP=$(printf "%d.%d.%d.%d" $((NODE_END_IP_NUM >> 24 & 0xFF)) $((NODE_END_IP_NUM >> 16 & 0xFF)) $((NODE_END_IP_NUM >> 8 & 0xFF)) $((NODE_END_IP_NUM & 0xFF)))

    # 写入 DHCP 配置
    ssh root@$NODE "cat <<EOF | tee -a /etc/dnsmasq.conf > /dev/null

# ${INTERFACE_PREFIX}${INDEX} DHCP 配置
interface=${INTERFACE_PREFIX}${INDEX}
dhcp-range=${NODE_START_IP},${NODE_END_IP},$(echo "$CIDR_START_IP" | awk -F/ '{print $2}'),8h
dhcp-option=option:router,$GATEWAY
dhcp-option=option:dns-server,$GATEWAY
EOF"
}


# ==============================
# 封装函数：配置 DHCP Failover
# ==============================
configure_dhcp_failover() {
    local NODE=$1
    local OUTPUT_FILE="/etc/dnsmasq.conf"

# 使用 SSH 远程清空文件内容并写入头部信息
    ssh root@$NODE "cat <<EOF |  tee $OUTPUT_FILE > /dev/null
# 动态生成的 DHCP 配置
# Node: $NODE
dhcp-leasefile=/var/lib/misc/dnsmasq.leases  # 持久化租约文件
listen-address=$VIRTUAL_IP  # 绑定到虚拟 IP 地址
EOF"
    # 配置 VLAN 的 DHCP
    local VLAN_INDEX=10
    for VLAN_CIDR in "${VLAN_CIDRS[@]}"; do
        local VLAN_GATEWAY=$(get_gateway_ip "$VLAN_CIDR" "$i")
        configure_dhcp_for_cidr "$NODE" "$VLAN_CIDR" "$VLAN_GATEWAY" "vlan" "$VLAN_INDEX" "${#NODES[@]}"
        ((VLAN_INDEX += 10))
    done

    # 配置 VXLAN 的 DHCP
    local VXLAN_INDEX=10
    for VXLAN_CIDR in "${VXLAN_CIDRS[@]}"; do
        local VXLAN_GATEWAY=$(get_gateway_ip "$VXLAN_CIDR" "$i")
        configure_dhcp_for_cidr "$NODE" "$VXLAN_CIDR" "$VXLAN_GATEWAY" "br_vxlan" "$VXLAN_INDEX" "${#NODES[@]}"
        ((VXLAN_INDEX += 10))
    done

    # 重启 dnsmasq 服务
    ssh root@$NODE "systemctl restart dnsmasq"

    # 输出调试信息
    echo "DHCP 配置已成功写入远程节点 $NODE 的 $OUTPUT_FILE 文件，并已重启 dnsmasq 服务。"
}


