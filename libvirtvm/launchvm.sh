#!/bin/bash

# 定义变量
VM_NAME=k8s01
workdir=$(pwd)                                   # 虚拟机名称
IMAGE_PATH=""                                    # 基础镜像路径
CLOUD_INIT_DIR="$workdir/cloud-init/$VM_NAME"    # cloud-init 配置目录
SSH_PUBLIC_KEY=$(cat /home/ryan/.ssh/id_rsa.pub) # 替换为你的公钥
USER_NAME="ubuntu"                               # 虚拟机用户
PASSWORD="passw0rd"                              # 虚拟机用户密码
RAM_SIZE="4096"                                  # 内存大小 (MB)
CPU_COUNT="4"                                    # CPU 核心数
DISK_SIZE="20G"                                  # 虚拟机磁盘大小
VG_NAME="vg_pve"                                 # LVM 卷组名称
LV_NAME="lv-${VM_NAME}"
NetWork=default

init_workdir() {
  # 创建工作目录

}

create_cloud_init() {
  # 创建 cloud-init 目录
  sudo apt install -y genisoimage
  mkdir -p $workdir/$VM_NAME
  cp /home/ryan/tools/virtual-proxmox/noble-server-cloudimg-amd64.img $workdir/$VM_NAME/
  mkdir -p "$CLOUD_INIT_DIR"
  cp /home/ryan/tools/virtual-proxmox/noble-server-cloudimg-amd64.img ${workdir}/$VM_NAME.img
  IMAGE_PATH=${workdir}/$VM_NAME.img

  # 创建 meta-data 文件
  cat <<EOF >"$CLOUD_INIT_DIR/meta-data"
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

  # 创建 user-data 文件
  cat <<EOF >"$CLOUD_INIT_DIR/user-data"
#cloud-config
users:
  - name: $USER_NAME
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $SSH_PUBLIC_KEY
EOF

  # 生成 cloud-init ISO 文件
  genisoimage -output "$CLOUD_INIT_DIR/cloud-init.iso" -volid cidata -joliet -rock \
    "$CLOUD_INIT_DIR/user-data" "$CLOUD_INIT_DIR/meta-data"
}

create_vm_using_lvm() {
  # 创建 LVM 逻辑卷
  if ! lvdisplay "/dev/$VG_NAME/$LV_NAME" >/dev/null 2>&1; then
    echo "Creating LVM logical volume $LV_NAME in volume group $VG_NAME..."
    lvcreate -L "$LV_SIZE" -n "$LV_NAME" "$VG_NAME"
  fi

  # 将基础镜像复制到 LVM 逻辑卷
  echo "Copying image to LVM logical volume..."
  qemu-img convert -f qcow2 -O raw "$IMAGE_PATH" "/dev/$VG_NAME/$LV_NAME"

  # 使用 virt-install 启动虚拟机
  virt-install \
    --name="$VM_NAME" \
    --ram="$RAM_SIZE" \
    --vcpus="$CPU_COUNT" \
    --disk path="/dev/$VG_NAME/$LV_NAME",format=raw,bus=virtio \
    --disk path="$CLOUD_INIT_DIR/cloud-init.iso",device=cdrom \
    --os-type=linux \
    --os-variant=ubuntu24.04 \
    --network network=$NetWork,model=virtio \
    --graphics none \
    --import

}

create_vm_using_image() {
  # 使用 virt-install 启动虚拟机
  virt-install \
    --name="$VM_NAME" \
    --ram="$RAM_SIZE" \
    --vcpus="$CPU_COUNT" \
    --disk path="$IMAGE_PATH",format=qcow2,bus=virtio \
    --disk path="$CLOUD_INIT_DIR/cloud-init.iso",device=cdrom \
    --os-variant=ubuntu24.04 \
    --network network=${NetWork},model=virtio \
    --graphics none \
    --import

}

resize_image() {
  resize=$1
  qemu-img resize $IMAGE_PATH +$1

  qemu-img info $IMAGE_PATH
}

resize_image_partition() {
  # 登录虚拟机
  #ssh ubuntu@<虚拟机IP>

  # 检查磁盘分区
  lsblk

  # 安装 growpart 工具（如果未安装）
  sudo apt update && sudo apt install -y cloud-guest-utils

  # 扩展分区
  sudo growpart /dev/vda 2

  # 扩展文件系统（ext4 示例）
  sudo resize2fs /dev/vda2

  # 检查结果
  df -h
}
main() {
  # create_cloud_init
  # create_vm_using_image
  resize_image 20G
}

main
