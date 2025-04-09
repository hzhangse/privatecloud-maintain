#!/bin/bash


# 定义全局参数
BGP_NODE_AS=65002                         # 当前节点 AS 号
BGP_NEIGHBOR_NODES=("192.168.122.93" "192.168.122.1")  # 邻居节点 IP 地址数组
BGP_NEIGHBOR_NODES_AS=(65001 65003)       # 邻居节点 AS 号数组

# 函数定义
configure_bgp() {
    # 检查全局参数是否完整
    if [[ -z "$BGP_NODE" || -z "$BGP_NODE_AS" ]]; then
        echo "Error: Missing required parameters (BGP_NODE or BGP_NODE_AS)."
        exit 1
    fi

    # 安装 FRRouting
    #echo "Installing FRRouting..."
    #ssh root@$BGP_NODE << EOF
    #apt update -y
    #apt install frr frr-pythontools -y
#EOF

    # 修改 /etc/frr/daemons 文件以启用 bgpd
    echo "Enabling bgpd in /etc/frr/daemons..."
    ssh root@$BGP_NODE << EOF
    sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
EOF

    # 动态生成 FRR 配置文件
    echo "Generating FRR configuration file..."
    FRR_CONFIG=$(cat << EOF
frr version 8.4.4
frr defaults traditional
no ipv6 forwarding
service integrated-vtysh-config
!
router bgp $BGP_NODE_AS
 bgp router-id $BGP_NODE
EOF
    )

    # 添加邻居关系和路由策略
    for i in "${!BGP_NEIGHBOR_NODES[@]}"; do
        NEIGHBOR="${BGP_NEIGHBOR_NODES[i]}"
        NEIGHBOR_AS="${BGP_NEIGHBOR_NODES_AS[i]}"
        FRR_CONFIG+="
 neighbor $NEIGHBOR remote-as $NEIGHBOR_AS"
    done

    FRR_CONFIG+="
 !
 address-family ipv4 unicast"

    # 添加 VLAN 和 VXLAN 网络声明
    for NETWORK in "${VLAN_CIDRS[@]}" "${VXLAN_CIDRS[@]}"; do
        FRR_CONFIG+="
  network $NETWORK"
    done

    # 添加邻居激活和路由策略
    for i in "${!BGP_NEIGHBOR_NODES[@]}"; do
        NEIGHBOR="${BGP_NEIGHBOR_NODES[i]}"
        FRR_CONFIG+="
  neighbor $NEIGHBOR route-map RM-IN in
  neighbor $NEIGHBOR route-map RM-OUT out
  neighbor $NEIGHBOR activate"
    done

    FRR_CONFIG+="
 exit-address-family
exit
!
route-map RM-IN permit 10
exit
!
route-map RM-OUT permit 10
exit
!
"

    # 将配置写入远程节点的 /etc/frr/frr.conf
    ssh root@$BGP_NODE "echo '$FRR_CONFIG' > /etc/frr/frr.conf"

    # 重启 FRRouting 服务
    echo "Restarting FRRouting service..."
    ssh root@$BGP_NODE << EOF
    systemctl restart frr
EOF

    echo "FRRouting installation and configuration completed successfully on $BGP_NODE."
}


