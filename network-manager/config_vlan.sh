#!/bin/bash

# 定义全局参数
IPROUTE2_MODE="interfaces" # 可选值：command, interfaces

VETHPAIR_HOST="veth_peer_host"
VETHPAIR_VLAN="veth_peer_vlan"

# 辅助函数：根据 CIDR 和节点顺序生成网关 IP
get_gateway_ip() {
    local CIDR=$1
    local INDEX=$2
    local BASE_IP=$(echo "$CIDR" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
    local GATEWAY_IP="${BASE_IP}.${INDEX}"
    echo "$GATEWAY_IP"
}

# 辅助函数：写入 /etc/network/interfaces 文件
write_interfaces_file() {
    local NODE=$1
    local FILE_CONTENT=$2
    ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
$FILE_CONTENT
EOF"
}

# 配置 VLAN（iproute2 模式，基于命令）
configure_vlan_iproute2_command() {
    local NODE=$1
    shift
    local VLAN_CIDRS=("$@")

    # 检查基础接口是否存在
    ssh root@$NODE <<EOF
    if ! ip link show "$BASE_INTERFACE" &>/dev/null; then
        echo "Error: Base interface '$BASE_INTERFACE' does not exist on node $NODE."
        exit 1
    fi

    # 创建 veth pair 并连接到 vmbr0 和 br-vlan
    if ! ip link show veth-peer-host &>/dev/null; then
        echo "Creating veth pair (veth-peer-host, veth-peer-vlan)..."
        ip link add veth-peer-host type veth peer name veth-peer-vlan || true
        ip link set veth-peer-host up
        ip link set veth-peer-vlan up
    else
        echo "veth pair (veth-peer-host, veth-peer-vlan) already exists. Skipping creation."
    fi

    # 将 veth-peer-host 绑定到 vmbr0
    echo "Adding veth-peer-host to $BASE_INTERFACE..."
    ip link set veth-peer-host master "$BASE_INTERFACE" || true

    # 创建专用网桥 br-vlan
    if ! ip link show br-vlan &>/dev/null; then
        echo "Creating bridge br-vlan..."
        ip link add name br-vlan type bridge || true
        ip link set br-vlan up || true
    else
        echo "Bridge br-vlan already exists. Skipping creation."
    fi

    # 将 veth-peer-vlan 添加到 br-vlan
    echo "Adding veth-peer-vlan to br-vlan..."
    ip link set veth-peer-vlan master br-vlan || true
EOF

    # 动态生成 VLAN 接口配置
    local VLAN_INDEX=10
    for i in "${!NODES[@]}"; do
        if [[ "$NODE" == "${NODES[i]}" ]]; then
            for VLAN_CIDR in "${VLAN_CIDRS[@]}"; do
                local VLAN_GATEWAY=$(get_gateway_ip "$VLAN_CIDR" "$((i + 1))")
                local VLAN_TAG=$((VLAN_TAG_BASE + VLAN_INDEX))
                local VLAN_INTERFACE="vlan${VLAN_TAG}"

                ssh root@$NODE <<EOF
                # 检查 VLAN 接口是否已存在
                if ip link show "$VLAN_INTERFACE" &>/dev/null; then
                    echo "VLAN interface '$VLAN_INTERFACE' already exists on node $NODE. Skipping creation."
                else
                    # 创建 VLAN 接口并添加到 br-vlan
                    echo "Creating VLAN interface '$VLAN_INTERFACE' with VLAN ID $VLAN_TAG..."
                    ip link add link br-vlan name "$VLAN_INTERFACE" type vlan id "$VLAN_TAG"
                    ip link set "$VLAN_INTERFACE" up
                fi

                # 配置 VLAN 接口的 IP 地址
                echo "Assigning IP address '$VLAN_GATEWAY' to VLAN interface '$VLAN_INTERFACE'..."
                ip addr flush dev "$VLAN_INTERFACE" 2>/dev/null || true  # 清除旧的 IP 地址
                ip addr add "$VLAN_GATEWAY/$(echo "$VLAN_CIDR" | cut -d'/' -f2)" dev "$VLAN_INTERFACE"
EOF

                ((VLAN_INDEX += 10))
            done
        fi
    done
}

#auto ${VETHPAIR_HOST}
#iface ${VETHPAIR_HOST} inet manual
#    pre-up ip link add ${VETHPAIR_HOST} type veth peer name ${VETHPAIR_VLAN} || true
#    up ip link set ${VETHPAIR_HOST} up && ip link set  ${VETHPAIR_VLAN} up || true
#    post-down ip link del  ${VETHPAIR_HOST} && ip link del  ${VETHPAIR_VLAN} || true
#auto ${VETHPAIR_VLAN}
#iface ${VETHPAIR_VLAN} inet manual
#auto $VLAN_INTERFACE
#iface $VLAN_INTERFACE inet static
#    address $VLAN_GATEWAY/$(echo "$VLAN_CIDR" | cut -d'/' -f2)
#    vlan_raw_device enp1s0
#    vlan_id $VLAN_TAG

# 配置 VLAN（iproute2 模式，基于写 interfaces 文件）
configure_vlan_iproute2_interfaces() {
    local NODE=$1
    shift
    local VLAN_CIDRS=("$@")

    # 动态生成 VLAN 接口配置
    local VLAN_INDEX=10
    for i in "${!NODES[@]}"; do
        if [[ "$NODE" == "${NODES[i]}" ]]; then
            for VLAN_CIDR in "${VLAN_CIDRS[@]}"; do
                local VLAN_GATEWAY=$(get_gateway_ip "$VLAN_CIDR" "$((i + 1))")
                local VLAN_TAG=$((VLAN_TAG_BASE + VLAN_INDEX))
                local VLAN_INTERFACE=${VLAN_iproute2_BRIDGE}_${VLAN_TAG}
                local VLAN_CONFIG="
# VLAN ID 10 的子接口配置
auto enp1s0.${VLAN_TAG}
iface enp1s0.${VLAN_TAG} inet manual
    vlan_raw_device enp1s0

# 配置专用网桥 
auto ${VLAN_INTERFACE}
iface ${VLAN_INTERFACE} inet static
    bridge_ports enp1s0.${VLAN_TAG}
    address $VLAN_GATEWAY/$(echo "$VLAN_CIDR" | cut -d'/' -f2) 
    netmask 255.255.255.0   
    bridge_fd 0
    bridge_stp off
    
"
                write_interfaces_file "$NODE" "$VLAN_CONFIG"
                ((VLAN_INDEX += 10))
            done
        fi
    done
}

generate_vlan_bridge() {
    local NODE=$1
    if [[ "$NETWORK_MODE" == "vlan" ]]; then
        local vlan_bridge_config="
        
auto $VLAN_OVS_BRIDGE   
iface $VLAN_OVS_BRIDGE  inet manual
    pre-up ovs-vsctl --may-exist add-br $VLAN_OVS_BRIDGE  || true
    up ip link set $VLAN_OVS_BRIDGE  up || true
    post-down ovs-vsctl del-br $VLAN_OVS_BRIDGE
    ovs_type OVSBridge
    ovs_ports ${VETHPAIR_VLAN} 
    
"
        write_interfaces_file "$NODE" "$vlan_bridge_config"
    elif [[ "$NETWORK_MODE" == "vlan-vxlan" ]]; then
        local vlan_bridge_config="
    
auto $VLAN_OVS_BRIDGE   
iface $VLAN_OVS_BRIDGE inet manual
    pre-up ovs-vsctl --may-exist add-br $VLAN_OVS_BRIDGE  || true
    up ip link set $VLAN_OVS_BRIDGE  up || true
    post-down ovs-vsctl del-br $VLAN_OVS_BRIDGE
    ovs_type OVSBridge
    ovs_ports ${VETHPAIR_VLAN}  
"
        write_interfaces_file "$NODE" "$vlan_bridge_config"
    fi

}

# 配置 VLAN（OVS 模式）
configure_vlan_ovs() {
    local NODE=$1
    shift
    local VLAN_CIDRS=("$@")

    # 创建 veth pair 并连接到 OVS 网桥
    local VETH_CONFIG="

auto ${VETHPAIR_HOST}
iface ${VETHPAIR_HOST} inet manual
    pre-up ip link add ${VETHPAIR_HOST} type veth peer name ${VETHPAIR_VLAN} || true
    up ip link set ${VETHPAIR_HOST} up && ip link set  ${VETHPAIR_VLAN} up || true
    post-down ip link del  ${VETHPAIR_HOST} && ip link del  ${VETHPAIR_VLAN} || true


auto ${VETHPAIR_VLAN}
iface ${VETHPAIR_VLAN} inet manual
    ovs_type OVSPort
    ovs_bridge $VLAN_OVS_BRIDGE   
    
"
    write_interfaces_file "$NODE" "$VETH_CONFIG"

    generate_vlan_bridge "$NODE"
    #在vmbr0上回写vethost
    append_to_bridge_ports "$NODE" "${BASE_INTERFACE}" "${VETHPAIR_HOST}"

    # 动态生成 VLAN 接口配置
    local VLAN_INDEX=10
    for i in "${!NODES[@]}"; do
        if [[ "$NODE" == "${NODES[i]}" ]]; then
            for VLAN_CIDR in "${VLAN_CIDRS[@]}"; do
                local VLAN_GATEWAY=$(get_gateway_ip "$VLAN_CIDR" "$((i + 1))")
                local VLAN_TAG=$((VLAN_TAG_BASE + VLAN_INDEX))
                local VLAN_INTERFACE=${VLAN_OVS_BRIDGE}_${VLAN_TAG}
                local VLAN_CONFIG="
auto $VLAN_INTERFACE
iface $VLAN_INTERFACE inet static
    pre-up ovs-vsctl --may-exist add-br $VLAN_OVS_BRIDGE  && ovs-vsctl add-port $VLAN_OVS_BRIDGE $VLAN_INTERFACE
    address $VLAN_GATEWAY/$(echo "$VLAN_CIDR" | cut -d'/' -f2)
    ovs_type OVSIntPort
    ovs_bridge  $VLAN_OVS_BRIDGE
    ovs_options tag=$VLAN_TAG
    
"
                write_interfaces_file "$NODE" "$VLAN_CONFIG"
                ((VLAN_INDEX += 10))
            done
        fi
    done
}

# 主函数：根据 VLAN_MODE 和 IPROUTE2_MODE 调用相应的配置方法
configure_vlan() {
    local NODE=$1
    shift
    local VLAN_CIDRS=("$@")

    if [[ "$VLAN_MODE" == "ovs" ]]; then
        configure_vlan_ovs "$NODE" "${VLAN_CIDRS[@]}"
    elif [[ "$VLAN_MODE" == "iproute2" ]]; then
        if [[ "$IPROUTE2_MODE" == "command" ]]; then
            configure_vlan_iproute2_command "$NODE" "${VLAN_CIDRS[@]}"
        elif [[ "$IPROUTE2_MODE" == "interfaces" ]]; then
            configure_vlan_iproute2_interfaces "$NODE" "${VLAN_CIDRS[@]}"
        else
            echo "Error: Unsupported IPROUTE2_MODE '$IPROUTE2_MODE'. Supported values are 'command' or 'interfaces'."
            exit 1
        fi
    else
        echo "Error: Unsupported VLAN_MODE '$VLAN_MODE'. Supported values are 'ovs' or 'iproute2'."
        exit 1
    fi
}
