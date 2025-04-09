#!/bin/bash

# ==============================
# 定义全局变量
# ==============================
BASE_INTERFACE="vmbr0"
#NODES=("192.168.122.91" "192.168.122.92" ) # 集群节点 IP 地址
NODES=("193.168.122.94" "192.168.122.91" ) 
NETWORK_MODE="vxlan"                                # 可选值：vlan, vxlan
VIRTUAL_IP="192.168.122.100"                             # 浮动 IP 地址
DNS_NODE="192.168.122.91"
BGP_NODE=""                  # BGP 节点 IP 地址

####vxlan相关配置参数
VXLAN_CIDRS=("172.16.10.0/24")           # VXLAN 子网 CIDR
VXLAN_MODE="p2p_ovs"                                         # 可选值：p2p, broadcast,p2p_ovs
VXLAN_ID=10                                              # VXLAN ID
VXLAN_MULTICAST_GROUP="239.0.0.1"                        # VXLAN 组播地址 (用于广播模式)
VXLAN_DSTPORT=4789                                       # VXLAN 目标端口
VXLAN_ID_BASE=10

####vlan相关配置参数
VLAN_CIDRS=( )            # VLAN 子网 CIDR
VLAN_MODE="iproute2"						# 可选值：ovs, iproute2
VLAN_TAG_BASE=0
VLAN_OVS_BRIDGE="ovsbr_vlan"
VLAN_iproute2_BRIDGE="br_vlan"





# 初始化计数器
i=1

# ==============================
# 加载辅助脚本
# ==============================
source ./config_vlan.sh
source ./config_vxlan.sh
source ./config_dhcp.sh
source ./config_keeplive.sh
source ./config_bgp.sh



# 方法：在 interfaces 文件中为指定接口追加 bridge-ports 值
append_to_bridge_ports() {
    local NODE=$1
    local INTERFACE=$2
    local APPEND=$3
    local FILE="/etc/network/interfaces"

    # 使用 SSH 检查文件是否存在，并显式使用 Bash 执行命令
    ssh root@$NODE "bash -c '
    echo \"Debug: Checking file existence...\"
    if [[ ! -f \"$FILE\" ]]; then
        echo \"Error: File \\\"$FILE\\\" does not exist on node $NODE.\"
        exit 1
    fi

    # 标志位：是否找到目标接口和 bridge-ports 行
    FOUND_INTERFACE=false
    FOUND_BRIDGE_PORTS=false

    # 遍历文件内容并进行处理
    while IFS= read -r LINE; do
        # 检查是否进入目标接口配置块
        if [[ \"\$LINE\" =~ ^[[:space:]]*auto[[:space:]]+$INTERFACE\$ ]]; then
            FOUND_INTERFACE=true
        elif [[ \"\$FOUND_INTERFACE\" == true && \"\$LINE\" =~ ^[[:space:]]*iface[[:space:]]+$INTERFACE[[:space:]]+inet ]]; then
            FOUND_INTERFACE=true
            echo \"Found iface block for interface: \$INTERFACE\"
        fi

        # 如果找到 bridge-ports 行，则追加值
        if [[ \"\$FOUND_INTERFACE\" == true && \"\$LINE\" =~ ^[[:space:]]*bridge-ports[[:space:]]+ ]]; then
            FOUND_BRIDGE_PORTS=true
            echo \"Found bridge-ports line: \$LINE\"
            # 检查是否已包含要追加的值
            if [[ \"\$LINE\" =~ (^|.*[[:space:]])$APPEND($|[[:space:]].*) ]]; then
                echo \"Value \\\"$APPEND\\\" already exists in \\\"bridge-ports\\\". Skipping append.\"
            else
                # 追加值
                sed -i \"/^[[:space:]]*bridge-ports[[:space:]]/ s/\$/ $APPEND/\" \"$FILE\"
                echo \"Appended \\\"$APPEND\\\" to \\\"bridge-ports\\\".\"
            fi
        fi
    done < \"$FILE\"

    # 如果未找到 bridge-ports 行，则在接口块末尾添加
    if [[ \"\$FOUND_INTERFACE\" == true && \"\$FOUND_BRIDGE_PORTS\" == false ]]; then
        # 找到接口块的最后一行，并在后面插入 bridge-ports 行
        sed -i \"/^[[:space:]]*iface[[:space:]]+$INTERFACE[[:space:]]+inet/a \    bridge-ports enp1s0 $APPEND\" \"$FILE\"
        echo \"Added new \\\"bridge-ports\\\" line with \\\"$APPEND\\\".\"
    fi

    echo \"Updated '$FILE' successfully on node $NODE.\"
    '"
}

# 定义函数：通过 SSH 替换远程节点的 Ubuntu 源为阿里云源
replace_remote_ubuntu_sources() {
    local NODE=$1  # 远程节点地址（如 user@192.168.1.100）
    local CODENAME=$(ssh "$NODE" "lsb_release -cs")  # 获取远程节点的系统代号
    local SOURCE_LIST="/etc/apt/sources.list"

    echo "正在备份远程节点的原始 sources.list 文件..."
    ssh "$NODE" << EOF
sudo cp "$SOURCE_LIST" "${SOURCE_LIST}.bak"
if [[ \$? -ne 0 ]]; then
    echo "Error: 备份失败，请检查权限或文件是否存在。"
    exit 1
fi
EOF

    echo "正在生成新的阿里云源配置..."
    ssh "$NODE" << EOF
cat << ALIYUN_SOURCES |  tee "$SOURCE_LIST" > /dev/null
# 阿里云 Ubuntu 源
deb https://mirrors.aliyun.com/debian/ bookworm main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm main non-free non-free-firmware contrib
deb https://mirrors.aliyun.com/debian-security/ bookworm-security main
deb-src https://mirrors.aliyun.com/debian-security/ bookworm-security main
deb https://mirrors.aliyun.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb https://mirrors.aliyun.com/debian/ bookworm-backports main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm-backports main non-free non-free-firmware contrib
ALIYUN_SOURCES

echo "更新完成！正在刷新软件包列表..."
apt update
if [[ \$? -eq 0 ]]; then
    echo "软件包列表刷新成功！"
else
    echo "Error: 软件包列表刷新失败，请检查 sources.list 文件内容。"
fi
EOF
}

# 封装函数：安装依赖
install_dependencies() {
    local NODE=$1
    #replace_remote_ubuntu_sources $NODE
    #ssh root@$NODE "apt install -y openvswitch-switch arping frr-pythontools dnsmasq iproute2 bridge-utils net-tools keepalived ipcalc"
    ssh root@$NODE "if [ ! -f /etc/openvswitch/conf.db ]; then
        ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
    fi"
    #ssh root@$NODE "echo 'sysctl -w net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p "
    #ssh root@$NODE "modprobe vxlan && echo 'vxlan' | tee /etc/modules-load.d/vxlan.conf && lsmod | grep vxlan"
    #ssh root@$NODE "systemctl restart openvswitch-switch && systemctl enable openvswitch-switch"
}

# 封装函数：根据 CIDR 和节点顺序生成网关 IP
get_gateway_ip() {
    local CIDR=$1
    local INDEX=$2
    local BASE_IP=$(echo "$CIDR" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
    local GATEWAY_IP="${BASE_IP}.${INDEX}"
    echo "$GATEWAY_IP"
}

# 封装函数：建立虚机网络
configure_base_lan() {
    local NODE=$1
    
    ssh root@$NODE "cat << 'EOF' > /etc/network/interfaces
# network interface settings; autogenerated
# Please do NOT modify this file directly, unless you know what
# you're doing.
#
# If you want to manage parts of the network configuration manually,
# please utilize the 'source' or 'source-directory' directives to do
# so.
# PVE will preserve these directives, but will NOT read its network
# configuration from sourced files, so do not attempt to move any of
# the PVE managed interfaces into external files!

auto lo
iface lo inet loopback

auto enp1s0
iface enp1s0 inet manual
	up ip link set enp1s0 up || true
	post-down ip link set enp1s0 down || true


auto $BASE_INTERFACE
iface $BASE_INTERFACE inet static
	address ${NODE}/24
	gateway 192.168.122.1
	bridge-ports enp1s0
	bridge-stp off
	bridge-fd 0
    
EOF"

}



# 封装函数：配置单个节点
configure_node() {
    local NODE=$1

    # 根据节点顺序分配网关 IP
    local VLAN_GATEWAYS=()
    local VXLAN_GATEWAYS=()
    for VLAN_CIDR in "${VLAN_CIDRS[@]}"; do
        VLAN_GATEWAYS+=("$(get_gateway_ip "$VLAN_CIDR" "$i")")
    done
    for VXLAN_CIDR in "${VXLAN_CIDRS[@]}"; do
        VXLAN_GATEWAYS+=("$(get_gateway_ip "$VXLAN_CIDR" "$i")")
    done
    # ==============================
    # 1. 安装依赖
    # ==============================
    install_dependencies "$NODE"

    # 清空现有的 /etc/network/interfaces 文件，并初始化基本配置
    configure_base_lan "$NODE"

    # ==============================
    # 2. 根据 NETWORK_MODE 和 VXLAN_MODE 选择配置逻辑
    # ==============================
    if [[ "$NETWORK_MODE" =~ vlan ]]; then
        configure_vlan "$NODE" "${VLAN_CIDRS[@]}"
    fi

    if [[ "$NETWORK_MODE" =~ vxlan ]]; then
        if [[ "$VXLAN_MODE" == "broadcast" ]]; then
            configure_vxlan_broadcast "$NODE" "${VXLAN_CIDRS[@]}"
        elif [[ "$VXLAN_MODE" == "p2p" || "$VXLAN_MODE" == "p2p_ovs" ]]; then
            configure_vxlan_p2p "$NODE" "${VXLAN_CIDRS[@]}"
        else
            echo "未知的 VXLAN_MODE: $VXLAN_MODE"
            exit 1
        fi
    fi

    # ==============================
    # 3. 配置 DHCP Failover
    # ==============================
    if [[ "$NODE" == "$DNS_NODE" ]]; then
       configure_dhcp_failover "$NODE"
    fi 
    
    # ==============================
    # 4. 配置 BGP
    # ==============================
    if [[ "$NODE" == "$BGP_NODE" ]]; then
       configure_bgp "$NODE"
    fi     
    # ==============================
    # 5. 配置 Keepalived
    # ==============================
    
    #configure_keepalived "$NODE" "$VIRTUAL_IP" "$BASE_INTERFACE" 
    # ==============================
    # 5. 重启网络服务以应用所有更改
    # ==============================
    ssh root@$NODE "systemctl daemon-reload && systemctl restart networking.service && systemctl restart openvswitch-switch "
}

# ==============================
# 主循环：遍历每个节点并调用配置函数
# ==============================
for NODE in "${NODES[@]}"; do
    echo "正在配置节点 $NODE..."
    configure_node "$NODE"
    ((i++))
done

echo "所有节点的配置已完成！"
