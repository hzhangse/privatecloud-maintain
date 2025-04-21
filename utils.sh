#!/bin/bash

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

# 封装函数：根据 CIDR 和节点顺序生成网关 IP
get_gateway_ip() {
  local CIDR=$1
  local INDEX=$2
  local BASE_IP=$(echo "$CIDR" | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
  local GATEWAY_IP="${BASE_IP}.${INDEX}"
  echo "$GATEWAY_IP"
}

# 解析 JSON 并设置环境变量和数组
parse_json_recursive() {
  local json="$1"
  local prefix="$2"

  # 遍历 JSON 的所有键
  for key in $(echo "$json" | jq -r 'keys[]'); do
    value=$(echo "$json" | jq -c ".[\"$key\"]")

    if [[ "$value" =~ ^\".*\"$ ]]; then
      # 字符串类型
      export "${prefix}${key}=$(echo "$value" | jq -r '.')"
      echo "Exported environment variable: ${prefix}${key}=$(echo "$value" | jq -r '.')"

    elif [[ "$value" == "null" || "$value" == "{}" ]]; then
      # 忽略 null 和空对象
      continue

    elif echo "$value" | jq -e 'type == "array"' &>/dev/null; then
      # 数组类型
      length=$(echo "$json" | jq ".[\"$key\"] | length")

      # 检查数组元素是否是对象
      if echo "$value" | jq -e '.[0] | type == "object"' &>/dev/null; then
        # 动态提取对象数组中的字段
        object_keys=($(echo "$value" | jq -r '.[0] | keys[]'))

        # 初始化数组映射
        for obj_key in "${object_keys[@]}"; do
          eval "array_map_${obj_key}=()"
        done

        # 遍历数组中的每个对象
        for ((i = 0; i < length; i++)); do
          item=$(echo "$json" | jq -c ".[\"$key\"][$i]")
          for obj_key in "${object_keys[@]}"; do
            obj_value=$(echo "$item" | jq -r ".[\"$obj_key\"] // empty")
            if [[ -n "$obj_value" ]]; then
              eval "array_map_${obj_key}+=(\"$obj_value\")"
            fi
          done
        done

        # 导出每个字段的数组
        for obj_key in "${object_keys[@]}"; do
          eval "${prefix}${key}_${obj_key}=(\"\${array_map_${obj_key}[@]}\")"
          export "${prefix}${key}_${obj_key}"
          echo "Exported Bash array: ${prefix}${key}_${obj_key}=(\"\${array_map_${obj_key}[@]}\")"
        done

      else
        # 普通数组处理逻辑
        array_values=()
        for ((i = 0; i < length; i++)); do
          item=$(echo "$json" | jq -c ".[\"$key\"][$i]")
          if [[ "$item" =~ ^\".*\"$ ]]; then
            # 数组元素为字符串
            array_values+=("$(echo "$item" | jq -r '.')")
          elif [[ "$item" =~ ^\{.*\}$ ]]; then
            # 数组元素为对象，递归解析
            parse_json_recursive "$item" "${prefix}${key}_${i}_"
          else
            # 其他情况直接添加
            array_values+=("$item")
          fi
        done
        # 将普通数组赋值给环境变量
        eval "${prefix}${key}=(${array_values[@]})"
        export "${prefix}${key}"
        echo "Exported Bash array: ${prefix}${key}=(${array_values[@]})"
      fi

    elif [[ "$value" =~ ^\{.*\}$ ]]; then
      # 对象类型，递归解析
      parse_json_recursive "$value" "${prefix}${key}_"

    else
      # 直接赋值
      export "${prefix}${key}=$value"
      echo "Exported environment variable: ${prefix}${key}=$value"
    fi
  done
}


# 数组转字符串函数
array_to_string() {
  local delimiter="$1" # 分隔符作为第一个参数
  shift                # 移除第一个参数（分隔符）
  local array=("$@")   # 剩余参数作为数组
  local IFS="$delimiter"
  echo "${array[*]}"
}

            # 将数组转换为逗号分隔的字符串
            # array_to_string1() {
            #     local delimiter="$1"
            #     shift
            #     IFS="$delimiter" eval 'echo "$*"'
            # }

# 字符串转数组函数
string_to_array() {
  local string="$1"
  local delimiter="$2"
  local IFS="$delimiter"
  read -r -a array <<<"$string"
  echo "${array[@]}"
}


# 定义函数：通过 SSH 替换远程节点的 Ubuntu 源为阿里云源
replace_remote_ubuntu_sources() {
  local NODE=$1 # 远程节点地址（如 user@192.168.1.100）
  local SOURCE_LIST="/etc/apt/sources.list"

  echo "正在备份远程节点的原始 sources.list 文件..."
  ssh root@$NODE "bash -c '<<EOF
cp "$SOURCE_LIST" "${SOURCE_LIST}.bak"
if [[ \$? -ne 0 ]]; then
    echo "Error: 备份失败，请检查权限或文件是否存在。"
    exit 1
fi
EOF

  echo "正在生成新的阿里云源配置..."
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
'"
}

# 封装函数：安装依赖
install_dependencies() {
  local NODE=$1
  replace_remote_ubuntu_sources $NODE
  ssh root@$NODE "apt install -y openvswitch-switch arping frr-pythontools  iproute2 bridge-utils net-tools keepalived ipcalc parted"

  ssh root@$NODE "sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p "
  ssh root@$NODE "sysctl -w net.ipv4.tcp_l3mdev_accept=1 && echo 'net.ipv4.tcp_l3mdev_accept=1' >> /etc/sysctl.conf && sysctl -p "
  ssh root@$NODE "sysctl -w net.ipv4.udp_l3mdev_accept=1 && echo 'net.ipv4.udp_l3mdev_accept=1' >> /etc/sysctl.conf && sysctl -p "
  ssh root@$NODE "modprobe vxlan && echo 'vxlan' | tee /etc/modules-load.d/vxlan.conf && lsmod | grep vxlan"
  ssh root@$NODE "systemctl restart openvswitch-switch && systemctl enable openvswitch-switch"
}
