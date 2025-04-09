#!/bin/bash

# ==============================
# 封装函数：配置 Keepalived
# ==============================
configure_keepalived() {
    local NODE=$1
    local VIRTUAL_IP=$2
    local ACT_NET_DEV=$3
    local STATE="MASTER"       # MASTER 或 BACKUP
    local PRIORITY=100    # 节点优先级
    if [ "$i" -eq 1 ]; then
        STATE="MASTER"          # 第一个节点是主节点
        PRIORITY=100            # 主节点优先级较高
    else
        STATE="BACKUP"          # 其他节点是备用节点
        PRIORITY=$((100 - i))   # 备用节点优先级递减
    fi
    # 配置 Keepalived
    ssh root@$NODE "cat << 'EOF' | tee /etc/keepalived/keepalived.conf > /dev/null
vrrp_instance VI_1 {
    state $STATE
    interface $ACT_NET_DEV
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass 1234
    }
    virtual_ipaddress {
        $VIRTUAL_IP
    }
}
EOF"
    echo "正在配置节点 $NODE 为 $STATE，优先级为 $PRIORITY..."
    # 重启 Keepalived 服务
    ssh root@$NODE "systemctl restart keepalived"

    # 输出调试信息
    echo "Keepalived 配置已成功写入远程节点 $NODE，并已重启服务。"
}
