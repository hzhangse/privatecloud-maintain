#!/bin/bash

# 定义节点列表和 VLAN 分配
NODES=("192.168.122.91" "192.168.122.93" "192.168.122.92") # 替换为你的集群节点 IP 地址
VLAN_GATEWAYS=("172.16.10.1" "172.16.20.2" "")            # 每个节点对应的 VLAN 网关

# 初始化计数器
i=1

for NODE in "${NODES[@]}"; do
    echo "Configuring VLAN with Open vSwitch on node: $NODE"

    # ==============================
    # 1. 安装 Open vSwitch
    # ==============================
   ssh root@$NODE "apt update && apt install -y openvswitch-switch && apt install -y arping && apt install frr-pythontools"
   ssh root@$NODE "systemctl stop dnsmasq && systemctl disable dnsmasq && apt remove -y dnsmasq && rm -rf /etc/dnsmasq.conf && apt install -y dnsmasq && systemctl disable --now dnsmasq"
   ssh root@$NODE "systemctl stop ovs-int && systemctl disable ovs-int && rm -rf /etc/systemd/system/ovs-init.service && rm -rf /etc/openvswitch/init-ovs.sh && rm -rf /etc/network/interfaces.d/* && rm -rf /etc/openvswitch/conf.db  "	
    # 确保 OVS 数据库文件存在并正确初始化
    ssh root@$NODE "if [ ! -f /etc/openvswitch/conf.db ]; then
        ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
    fi"

    # 启动并启用 OVS 服务
    ssh root@$NODE "systemctl restart openvswitch-switch && systemctl enable openvswitch-switch"

    # ==============================
    # 2. 配置传统桥接接口 vmbr0
    # ==============================
    ssh root@$NODE "cat << 'EOF' | tee /etc/network/interfaces > /dev/null
auto lo
iface lo inet loopback
   
# 主桥接接口 vmbr0（保留传统桥接）
auto enp1s0
iface enp1s0 inet manual
    up ip link set enp1s0 up || true
    post-down ip link del enp1s0 || true
	
	    
auto vmbr0
iface vmbr0 inet static
    address $NODE/24
    gateway 192.168.122.1
    bridge-ports enp1s0 
    bridge-stp off
    bridge-fd 0
    
		
	
source /etc/network/interfaces.d/*
EOF"




    
    



    # ==============================
    # 6. 重启网络服务以应用所有更改
    # ==============================
    # 重新加载 systemd 配置
    ssh root@$NODE "systemctl daemon-reload"
    ssh root@$NODE "systemctl restart networking.service"
    # 启用并启动 ovs-init 服务
    #ssh root@$NODE "systemctl enable ovs-init.service && systemctl restart ovs-init.service"
    # 增加计数器
    ((i++))
done

echo "所有节点配置完成！"
