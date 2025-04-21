#!/bin/bash

BASE_INTERFACE="vmbr0"
workdir=$(pwd)
source $(dirname "$PWD")/utils.sh


configure_bgp() {
  BGP_NODE=$1
  BGP_NODE_AS=$2
  BGP_NODE_NETWORKS=$3
  NEIGHBOR_IPS=$4
  NEIGHBOR_ASS=$5
  NEIGHBOR_CIDR=$6

  IFS='|' read -ra NETWORK_CIDRS <<<"$BGP_NODE_NETWORKS"
  IFS='|' read -ra BGP_NEIGHBOR_NODES <<<"$NEIGHBOR_IPS"
  IFS='|' read -ra BGP_NEIGHBOR_NODES_AS <<<"$NEIGHBOR_ASS"
  IFS='|' read -ra BGP_NEIGHBOR_NODES_CIDR <<<"$NEIGHBOR_CIDR"

  if [[ -z "$BGP_NODE" || -z "$BGP_NODE_AS" || -z "$NEIGHBOR_IPS" || -z "$NEIGHBOR_ASS" ]]; then
    echo "Error: Missing required parameters."
    exit 1
  fi
  echo "BGP_NODE:$BGP_NODE"
  ssh root@$BGP_NODE "bash -c 'sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons' "


  FRR_CONFIG=$(
    cat <<EOF
frr version 8.4.4
frr defaults traditional
no ipv6 forwarding
log file /var/log/frr/bgpd.log
log stdout
service integrated-vtysh-config
!
router bgp ${BGP_NODE_AS}
 bgp router-id ${BGP_NODE}
EOF
  )

  for i in "${!BGP_NEIGHBOR_NODES[@]}"; do
    NEIGHBOR="${BGP_NEIGHBOR_NODES[i]}"
    NEIGHBOR_AS="${BGP_NEIGHBOR_NODES_AS[i]}"
    NEIGHBOR_CIDR="${BGP_NEIGHBOR_NODES_CIDR[i]}"
    FRR_CONFIG+="
 neighbor ${NEIGHBOR} remote-as ${NEIGHBOR_AS}
 neighbor ${NEIGHBOR} ebgp-multihop 2
 neighbor ${NEIGHBOR} update-source ${BGP_NODE}"
  done

  FRR_CONFIG+="
 !
 address-family ipv4 unicast"

  for NETWORK in "${NETWORK_CIDRS[@]}"; do
    FRR_CONFIG+="
  network ${NETWORK}"
  done

  for i in "${!BGP_NEIGHBOR_NODES[@]}"; do
    NEIGHBOR="${BGP_NEIGHBOR_NODES[i]}"
    FRR_CONFIG+="
  neighbor ${NEIGHBOR} route-map RM-IN in
  neighbor ${NEIGHBOR} route-map RM-OUT out
  neighbor ${NEIGHBOR} activate"
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
  for i in "${!BGP_NEIGHBOR_NODES[@]}"; do
    NEIGHBOR_CIDR="${BGP_NEIGHBOR_NODES_CIDR[i]}"

   if [[ -n "$NEIGHBOR_CIDR" ]]; then   
     neighbor_gw=$(get_gateway_ip "$BGP_NODE" "1")
     FRR_CONFIG+="
ip route ${NEIGHBOR_CIDR} ${neighbor_gw} " 
   fi    
  done

ssh root@$BGP_NODE "bash -c 'cat > /etc/frr/frr.conf <<EOF
${FRR_CONFIG}
EOF
systemctl restart frr'"
}

main() {
  JSON_FILE="/home/ryan/tools/virtual-proxmox/libvirt/privatecloud-maintain/network-manager/bgp.json"

  # 初始化空数组
  nodes=()

  # 使用 while read 循环读取每一行
  while IFS= read -r line; do
    nodes+=("$line")
  done < <(jq -c '.BGPConfigurations[]' "$JSON_FILE")

  # 打印数组内容
  for bgpnode in "${nodes[@]}"; do
    #parse_json_recursive "$node" ""
    node=$(echo "$bgpnode" | jq -r '.BGPNode')
    # 开始解析# 初始化计数器
    echo "配置node开始"
    BGP_NODE=$(echo "$node" | jq -r '.NODE')
    BGP_NODE_AS=$(echo "$node" | jq -r '.AS')
    BGP_NODE_NETWORKS=($(echo "$node" | jq -r '.NetWorks[].cidr // empty'))
    BGP_NEIGHBOR_NODES=($(echo "$node" | jq -r '.BGPNeighbors[].IP'))
    BGP_NEIGHBOR_NODES_CIDR=($(echo "$node" | jq -r '.BGPNeighbors[].CIDR'))
    BGP_NEIGHBOR_NODES_AS=($(echo "$node" | jq -r '.BGPNeighbors[].AS'))

    NEIGHBOR_IPS=$(
      IFS='|'
      echo "${BGP_NEIGHBOR_NODES[*]}"
    )
    NEIGHBOR_ASS=$(
      IFS='|'
      echo "${BGP_NEIGHBOR_NODES_AS[*]}"
    )
    NETWORK_CIDRS=$(
      IFS='|'
      echo "${BGP_NODE_NETWORKS[*]}"
    )

    configure_bgp "$BGP_NODE" "$BGP_NODE_AS" "$NETWORK_CIDRS" "$NEIGHBOR_IPS" "$NEIGHBOR_ASS" "$BGP_NEIGHBOR_NODES_CIDR"

  done

}

main

# 定义全局参数
declare -A bgp_nodes=(
  ["192.168.122.91"]="65001 193.168.122.94 65002 192.168.122.1 65003"
  ["193.168.122.94"]="65002 192.168.122.91 65001 192.168.122.1 65003"
  ["192.168.122.1"]="65003 192.168.122.91 65001 193.168.122.94 65002"
)

export_json() {
  echo '{
  "BGPConfigurations": ['
  first=true
  for bgp_node_ip in "${!bgp_nodes[@]}"; do
    IFS=' ' read -r -a node_info <<<"${bgp_nodes[$bgp_node_ip]}"
    BGP_NODE_AS="${node_info[0]}"
    neighbor_ips=("${node_info[@]:1:$((${#node_info[@]} / 2))}")
    neighbor_ases=("${node_info[@]:$((${#node_info[@]} / 2 + 1))}")

    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    echo '    {
      "BGPNode": {
        "ip": "'"$bgp_node_ip"'",
        "AS": '"$BGP_NODE_AS"',
        "NetWorks": [], 
        "BGPNeighbors": ['
    for i in "${!neighbor_ips[@]}"; do
      neighbor_ip="${neighbor_ips[$i]}"
      neighbor_as="${neighbor_ases[$i]}"
      if [ $i -gt 0 ]; then
        echo ","
      fi
      echo '          {
            "IP": "'"$neighbor_ip"'",
            "AS": '"$neighbor_as"'
          }' | sed 's/          //'
    done
    echo '
        ]
      }
    }'
  done
  echo '
  ]
}'
}

map_to_env_vars() {
  local JSON_FILE="$1"
  nodes=$(jq -c '.BGPConfigurations[].BGPNode' "$JSON_FILE")

  declare -A bgp_nodes
  while IFS= read -r node; do
    BGP_NODE=$(echo "$node" | jq -r '.ip')
    BGP_NODE_AS=$(echo "$node" | jq -r '.AS')
    BGP_NODE_NETWORKS=($(echo "$node" | jq -r '.NetWorks[].cidr // empty'))
    BGP_NEIGHBOR_NODES=($(echo "$node" | jq -r '.BGPNeighbors[].IP'))
    BGP_NEIGHBOR_NODES_AS=($(echo "$node" | jq -r '.BGPNeighbors[].AS'))

    neighbors_info=""
    for i in "${!BGP_NEIGHBOR_NODES[@]}"; do
      neighbors_info+="${BGP_NEIGHBOR_NODES[$i]} ${BGP_NEIGHBOR_NODES_AS[$i]} "
    done
    neighbors_info=${neighbors_info% }

    bgp_nodes["$BGP_NODE"]="$BGP_NODE_AS $neighbors_info"
  done <<<"$nodes"

  echo "bgp_nodes=("
  for key in "${!bgp_nodes[@]}"; do
    echo "  [\"$key\"]=\"${bgp_nodes[$key]}\""
  done
  echo ")"
}
