#!/bin/bash

# 提取通用函数：添加 VXLAN 接口配置
add_vxlan_interface_config() {
    local NODE=$1
    local VXLAN_INDEX=$2
    local REMOTE_HOSTNAME=$3
    local REMOTE_VNI=$4
    local REMOTE_NODE=$5
    local VXLAN_MODE=$6

    if [[ "$VXLAN_MODE" == "p2p_ovs" ]]; then
        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
auto vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME
iface vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME inet manual        
    pre-up ovs-vsctl --may-exist add-br br_vxlan${VXLAN_INDEX}_tun && ovs-vsctl add-port br_vxlan${VXLAN_INDEX}_tun vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME  -- set interface vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME type=vxlan options:remote_ip=$REMOTE_NODE options:key=$REMOTE_VNI options:dst_port=$VXLAN_DSTPORT || true
    up ip link set vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME mtu 1450 up || true
    post-down ovs-vsctl del-port br_vxlan${VXLAN_INDEX}_tun  vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME || true    
    ovs_type OVSInterface
#    ovs_bridge br_vxlan$VXLAN_INDEX_tun
#    ovs_options "type=vxlan,remote_ip=$REMOTE_NODE,dest_port=$VXLAN_DSTPORT,key=$REMOTE_VNI"
    
EOF"
    elif [[ "$VXLAN_MODE" == "p2p" ]]; then
        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
auto vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME
iface vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME inet manual
    pre-up ip link add vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME type vxlan id $REMOTE_VNI remote $REMOTE_NODE dev $BASE_INTERFACE dstport $VXLAN_DSTPORT || true
#    up ip link set vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME mtu 1450 up || true
    post-down ip link del vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME || true
    
EOF"
    else
        echo "未知的 VXLAN_MODE: $VXLAN_MODE"
        exit 1
    fi
}


# 函数：生成veth pair配置
generate_veth_pair() {
    local NODE=$1
    local VXLAN_INDEX=$2
    local MODE=$3

    if [[ "$MODE" == "p2p" ]]; then
        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
auto vxlan${VXLAN_INDEX}-pe-host
iface vxlan${VXLAN_INDEX}-pe-host inet manual
    pre-up ip link add vxlan${VXLAN_INDEX}-pe-host type veth peer name vxlan${VXLAN_INDEX}-pe-tun || true
    up ip link set vxlan${VXLAN_INDEX}-pe-host up && ip link set vxlan${VXLAN_INDEX}-pe-tun up || true
    post-down ip link del vxlan${VXLAN_INDEX}-pe-host && ip link del vxlan${VXLAN_INDEX}-pe-tun || true

auto vxlan${VXLAN_INDEX}-pe-tun
iface vxlan${VXLAN_INDEX}-pe-tun inet manual
    up ip link set vxlan${VXLAN_INDEX}-pe-tun up || true
    post-down ip link del vxlan${VXLAN_INDEX}-pe-tun || true
    
EOF"
    elif [[ "$MODE" == "p2p_ovs" ]]; then
        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
        
auto vxlan${VXLAN_INDEX}-pe-tun
iface vxlan${VXLAN_INDEX}-pe-tun inet manual
    pre-up ovs-vsctl --may-exist add-br br_vxlan${VXLAN_INDEX}_tun && ovs-vsctl add-port br_vxlan${VXLAN_INDEX}_tun vxlan${VXLAN_INDEX}-pe-tun -- set interface vxlan${VXLAN_INDEX}-pe-tun type=patch options:peer=vxlan${VXLAN_INDEX}-pe-host  
    up ip link set vxlan${VXLAN_INDEX}-pe-tun up || true
    post-down ovs-vsctl del-port br_vxlan${VXLAN_INDEX}_tun vxlan${VXLAN_INDEX}-pe-tun
#    ovs_type OVSInterface
#    ovs_bridge br_vxlan${VXLAN_INDEX}_tun
        
auto vxlan${VXLAN_INDEX}-pe-host
iface vxlan${VXLAN_INDEX}-pe-host inet manual
    pre-up ovs-vsctl --may-exist add-br br_vxlan${VXLAN_INDEX} && ovs-vsctl add-port br_vxlan$VXLAN_INDEX vxlan${VXLAN_INDEX}-pe-host -- set interface vxlan${VXLAN_INDEX}-pe-host type=patch options:peer=vxlan${VXLAN_INDEX}-pe-tun 
    up ip link set vxlan${VXLAN_INDEX}-pe-host up || true
    post-down ovs-vsctl del-port br_vxlan$VXLAN_INDEX  vxlan${VXLAN_INDEX}-pe-host || true
#    ovs_type OVSInterface
#    ovs_bridge br_vxlan$VXLAN_INDEX

    
EOF"
    fi
}



# 提取通用函数：添加 VXLAN 网桥配置
add_vxlan_bridge_config() {
    local NODE=$1
    local VXLAN_INDEX=$2
    local VXLAN_GATEWAY=$3
    local VXLAN_MODE=$4

    if [[ "$VXLAN_MODE" == "p2p_ovs" ]]; then
        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
# VXLAN 网桥配置
auto br_vxlan$VXLAN_INDEX
iface br_vxlan$VXLAN_INDEX inet static
    pre-up ovs-vsctl --may-exist add-br br_vxlan$VXLAN_INDEX || true
    up     ip link set br_vxlan$VXLAN_INDEX up || true
    down ovs-vsctl del-br br_vxlan$VXLAN_INDEX  
    post-down ovs-vsctl del-br br_vxlan$VXLAN_INDEX  
    ovs_type OVSBridge   
    address $VXLAN_GATEWAY/24
    netmask 255.255.255.0 
    ovs_ports vxlan${VXLAN_INDEX}-pe-host

# VXLAN tunnel 网桥配置
auto br_vxlan${VXLAN_INDEX}_tun
iface br_vxlan${VXLAN_INDEX}_tun inet static
    pre-up ovs-vsctl --may-exist add-br br_vxlan${VXLAN_INDEX}_tun || true
    up     ip link set br_vxlan${VXLAN_INDEX}_tun up || true
    down ovs-vsctl del-br br_vxlan${VXLAN_INDEX}_tun   
    post-down ovs-vsctl del-br br_vxlan${VXLAN_INDEX}_tun  
    ovs_type OVSBridge
    ovs_ports vxlan$VXLAN_INDEX-pe-tun $(for REMOTE_NODE in "${NODES[@]}"; do
        if [[ "$REMOTE_NODE" != "$NODE" ]]; then
            REMOTE_HOSTNAME=$(ssh root@$REMOTE_NODE hostname)
            echo -n "vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME "
        fi
    done)    
      
EOF"
    elif [[ "$VXLAN_MODE" == "p2p" ]]; then
        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
# VXLAN 网桥配置
auto br_vxlan$VXLAN_INDEX
iface br_vxlan$VXLAN_INDEX inet static
    bridge_ports vxlan${VXLAN_INDEX}-pe-host
    address $VXLAN_GATEWAY/24
    netmask 255.255.255.0 

# VXLAN tunnel 网桥配置
auto br_vxlan${VXLAN_INDEX}_tun
iface br_vxlan${VXLAN_INDEX}_tun inet static
    bridge_ports vxlan$VXLAN_INDEX-pe-tun $(for REMOTE_NODE in "${NODES[@]}"; do
        if [[ "$REMOTE_NODE" != "$NODE" ]]; then
            REMOTE_HOSTNAME=$(ssh root@$REMOTE_NODE hostname)
            echo -n "vxlan$VXLAN_INDEX-to-$REMOTE_HOSTNAME "
        fi
    done)  
      
EOF"
    fi
}

# 封装函数：配置广播模式 VXLAN
configure_vxlan_broadcast() {
    local NODE=$1
    shift
    local VXLAN_CIDRS=("$@")

    ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
# 动态生成的 VXLAN 广播模式配置
EOF"

    local VXLAN_INDEX=10
    for VXLAN_CIDR in "${VXLAN_CIDRS[@]}"; do
        local VXLAN_GATEWAY=$(get_gateway_ip "$VXLAN_CIDR" "$i")
        local REMOTE_VNI=$((VXLAN_ID_BASE + VXLAN_INDEX))

        ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
auto vxlan$VXLAN_INDEX
iface vxlan$VXLAN_INDEX inet manual
    pre-up ip link add vxlan$VXLAN_INDEX type vxlan id $REMOTE_VNI group $VXLAN_MULTICAST_GROUP dev $BASE_INTERFACE dstport $VXLAN_DSTPORT || true
    up ip link set vxlan$VXLAN_INDEX up || true
    down ip link del vxlan$VXLAN_INDEX || true

auto br_vxlan$VXLAN_INDEX
iface br_vxlan$VXLAN_INDEX inet static
    bridge_ports vxlan$VXLAN_INDEX
    address $VXLAN_GATEWAY/24
    netmask 255.255.255.0
EOF"

        ((VXLAN_INDEX += 10))
    done
}

# 封装函数：配置 P2P VXLAN
configure_vxlan_p2p() {
    local NODE=$1
    shift
    local VXLAN_CIDRS=("$@")

    ssh root@$NODE "cat << 'EOF' | tee -a /etc/network/interfaces > /dev/null
# 动态生成的 VXLAN P2P 模式配置
EOF"

    local VXLAN_INDEX=10
    for VXLAN_CIDR in "${VXLAN_CIDRS[@]}"; do
        local VXLAN_GATEWAY=$(get_gateway_ip "$VXLAN_CIDR" "$i")
        local REMOTE_VNI=$((VXLAN_ID_BASE + VXLAN_INDEX))

        for REMOTE_NODE in "${NODES[@]}"; do
            if [[ "$REMOTE_NODE" != "$NODE" ]]; then
                REMOTE_HOSTNAME=$(ssh root@$REMOTE_NODE hostname)
                add_vxlan_interface_config "$NODE" "$VXLAN_INDEX" "$REMOTE_HOSTNAME" "$REMOTE_VNI" "$REMOTE_NODE" "$VXLAN_MODE"
                ((REMOTE_VNI++))
            fi
        done

        generate_veth_pair "$NODE" "$VXLAN_INDEX"  "$VXLAN_MODE"
        add_vxlan_bridge_config "$NODE" "$VXLAN_INDEX" "$VXLAN_GATEWAY" "$VXLAN_MODE"
        ((VXLAN_INDEX += 10))
    done
}



