#!/bin/bash

# --- 脚本配置变量 ---
BACKUP_DIR="/media/8T/4Backups/Backup" # 备份镜像文件保存的目录

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本必须以 root 用户身份运行！请使用 sudo ./your_script_name.sh"
    exit 1
fi

# --- 安装所需软件 ---
echo "--- 阶段 1/8: 检查并安装所需软件 ---"
REQUIRED_PKGS="dosfstools parted kpartx rsync jq"
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "正在安装 $pkg..."
        apt update && apt install -y "$pkg"
        if [ $? -ne 0 ]; then
            echo "错误：安装 $pkg 失败。请检查网络连接或 APT 源。"
            exit 1
        fi
    fi
done
echo "所有必要软件已准备就绪。"

# --- 定义清理函数 ---
cleanup() {
    echo "--- 执行清理操作 ---"
    # 解挂载 /mnt/boot_temp 和 /mnt/root_temp
    if mountpoint -q /mnt/boot_temp; then
        umount /mnt/boot_temp
        rmdir /mnt/boot_temp
        echo "/mnt/boot_temp 已卸载并删除。"
    fi
    if mountpoint -q /mnt/root_temp; then
        umount /mnt/root_temp
        rmdir /mnt/root_temp
        echo "/mnt/root_temp 已卸载并删除。"
    fi

    # 解除循环设备映射
    if [ -n "$loopdevice" ] && losetup "$loopdevice" &>/dev/null; then
        kpartx -d "$loopdevice" &>/dev/null # 静默执行
        losetup -d "$loopdevice" &>/dev/null # 静默执行
        echo "已解除循环设备 $loopdevice 及其映射。"
    fi
    echo "清理完成。"
}
trap cleanup EXIT # 在脚本退出时（无论成功或失败）调用清理函数

# --- 准备备份目录 ---
echo "--- 阶段 2/8: 准备备份目录 ---"
mkdir -p "$BACKUP_DIR"
if [ $? -ne 0 ]; then
    echo "错误：无法创建备份目录 $BACKUP_DIR。请检查路径和权限。"
    exit 1
fi
echo "备份目录已确认/创建：$BACKUP_DIR"

# --- 获取 SD 卡/系统盘信息 ---
echo "--- 阶段 3/8: 自动检测系统盘并获取信息 ---"

# 查找根目录 / 的挂载设备
ROOT_DEVICE_PARTITION=$(df -P / | tail -n 1 | awk '{print $1}')
if [ -z "$ROOT_DEVICE_PARTITION" ]; then
    echo "错误：无法确定根目录 / 的挂载分区。退出。"
    exit 1
fi

# 从分区名获取其所在的物理设备
# 例如 /dev/sda2 -> /dev/sda
# /dev/mmcblk0p2 -> /dev/mmcblk0
if [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
else
    echo "错误：无法解析根目录所在设备的类型（非 mmcblk 或 sd 设备）。退出。"
    exit 1
fi

echo "检测到系统盘设备为：$SD_DEVICE"

# 假定引导分区是第一个分区，根分区是第二个分区
BOOT_PART="${SD_DEVICE}p1"
ROOT_PART="${SD_DEVICE}p2" 

# 检查系统盘设备是否存在
if [ ! -b "$SD_DEVICE" ]; then
    echo "错误：系统盘设备 $SD_DEVICE 不存在。请确认设备是否正常。"
    exit 1
fi

# 获取分区详细信息 (使用 lsblk 的 JSON 输出)
# 这里仅获取 NAME 和 PARTUUID，因为其他信息可以在需要时重新获取
PART_INFO=$(lsblk -o NAME,PARTUUID,FSTYPE,MOUNTPOINTS,SIZE "${SD_DEVICE}" -J)
if [ $? -ne 0 ]; then
    echo "错误：无法获取设备 $SD_DEVICE 的分区信息。请检查 lsblk 和 jq 是否正常工作。"
    exit 1
fi

# 从 JSON 输出中解析所需信息
# 过滤掉不存在的分区（例如，如果分区结构不是p1/p2，或者只有p1）
BOOT_MOUNTPOINT=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$BOOT_PART")\") | .mountpoints[0] // \"\"")
ORIG_BOOT_PARTUUID=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$BOOT_PART")\") | .partuuid // \"\"")
ORIG_ROOT_PARTUUID=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$ROOT_PART")\") | .partuuid // \"\"")
BOOT_FSTYPE=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$BOOT_PART")\") | .fstype // \"\"")
ROOT_FSTYPE=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$ROOT_PART")\") | .fstype // \"\"")

# 再次验证分区信息是否有效
if [ -z "$BOOT_MOUNTPOINT" ] || [ -z "$ORIG_BOOT_PARTUUID" ] || [ -z "$ORIG_ROOT_PARTUUID" ] || [ -z "$BOOT_FSTYPE" ] || [ -z "$ROOT_FSTYPE" ]; then
    echo "错误：未能完全获取系统盘的关键分区信息 (引导挂载点, PARTUUIDs, 文件系统类型)。"
    echo "这可能是因为系统分区结构不符合预期的 ${SD_DEVICE}p1/${SD_DEVICE}p2 模式。"
    echo "请手动检查分区并修改脚本。"
    exit 1
fi

SD_CARD_TOTAL_BYTES=$(blockdev --getsize64 "$SD_DEVICE") # 获取系统盘总字节数
if [ $? -ne 0 ]; then
    echo "警告：无法精确获取系统盘总大小。将回退到使用已用空间估算镜像大小。"
    # 如果 blockdev 失败，回退到估算方法
    ROOT_USED_SIZE_KB=$(df -P / | tail -n 1 | awk '{print $3}') # 根分区已用空间 (KB)
    BOOT_TOTAL_SIZE_KB=$(df -P "$BOOT_MOUNTPOINT" | tail -n 1 | awk '{print $2}') # 引导分区总大小 (KB)
    # 估算镜像大小：根分区已用 + 引导分区总大小 + 20% 余量
    IMAGE_SIZE_KB=$(((ROOT_USED_SIZE_KB + BOOT_TOTAL_SIZE_KB) * 12 / 10))
else
    # 镜像大小设置为系统盘总大小，并增加少量余量以确保兼容性
    # 增加 100MB 作为一个安全边际，以弥补分区表或文件系统开销
    RESERVED_BYTES=$((100 * 1024 * 1024)) # 100MB
    IMAGE_SIZE_KB=$(((SD_CARD_TOTAL_BYTES + RESERVED_BYTES) / 1024))
fi

echo "系统盘设备: $SD_DEVICE"
echo "引导分区挂载点: $BOOT_MOUNTPOINT (PARTUUID: $ORIG_BOOT_PARTUUID)"
echo "根分区 PARTUUID: $ORIG_ROOT_PARTUUID"
echo "估算镜像大小: $((IMAGE_SIZE_KB / 1024)) MB"

# --- 确认继续 ---
read -p "请确认以上信息无误，即将创建系统盘备份镜像文件。(y/N): " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "备份已取消。"
    exit 0
fi

# --- 创建空的镜像文件 ---
echo "--- 阶段 4/8: 创建空的镜像文件 ---"
IMAGE_FILE_NAME="rpi-$(date +%Y%m%d%H%M%S).img"
DEST_IMG_PATH="${BACKUP_DIR}/${IMAGE_FILE_NAME}"

echo "正在创建镜像文件：$DEST_IMG_PATH (大小约为 $((IMAGE_SIZE_KB / 1024)) MB)..."
dd if=/dev/zero of="$DEST_IMG_PATH" bs=1K count=0 seek="$IMAGE_SIZE_KB" status=progress
if [ $? -ne 0 ]; then echo "错误：创建镜像文件失败。退出。" ; exit 1; fi

# --- 在镜像文件中创建分区表 ---
echo "--- 阶段 5/8: 在镜像中创建分区表 ---"
# 获取原始分区的起始和结束扇区，以便在新镜像中精确复制
# fdisk -l 命令的输出可能因版本和设备而异，使用 grep + awk 更稳定
PARTED_INFO=$(fdisk -l "$SD_DEVICE")
BOOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $2}')
BOOT_END_SECTOR=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $3}')
ROOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "^${ROOT_PART}" | awk '{print $2}')

if [ -z "$BOOT_START_SECTOR" ] || [ -z "$BOOT_END_SECTOR" ] || [ -z "$ROOT_START_SECTOR" ]; then
    echo "错误：无法从 fdisk 输出中解析分区起始/结束扇区。请检查 fdisk -l $SD_DEVICE 的输出。"
    exit 1
fi

# 确保 parted 使用扇区单位 's'
BOOT_START_PARTED="${BOOT_START_SECTOR}s"
BOOT_END_PARTED="${BOOT_END_SECTOR}s"
ROOT_START_PARTED="${ROOT_START_SECTOR}s"
ROOT_END_PARTED="100%" # 根分区通常扩展到磁盘末尾

parted "$DEST_IMG_PATH" --script -- mklabel msdos
if [ $? -ne 0 ]; then echo "错误：创建分区标签失败。退出。" ; exit 1; fi
parted "$DEST_IMG_PATH" --script -- mkpart primary fat32 "$BOOT_START_PARTED" "$BOOT_END_PARTED"
if [ $? -ne 0 ]; then echo "错误：创建引导分区失败。退出。" ; exit 1; fi
parted "$DEST_IMG_PATH" --script -- mkpart primary ext4 "$ROOT_START_PARTED" "$ROOT_END_PARTED"
if [ $? -ne 0 ]; then echo "错误：创建根分区失败。退出。" ; exit 1; fi

echo "分区表创建完成。"

# --- 挂载镜像文件并格式化分区 ---
echo "--- 阶段 6/8: 挂载镜像文件并格式化分区 ---"
loopdevice=$(losetup -f --show "$DEST_IMG_PATH")
if [ $? -ne 0 ] || [ -z "$loopdevice" ]; then
    echo "错误：无法挂载镜像文件为循环设备。退出。" ; exit 1;
fi

# 映射分区
device_mapper_name=$(basename "$loopdevice")
# kpartx -va 会返回类似 "add map loop0p1 (253:0) to loop0" 的信息
kpartx_output=$(kpartx -va "$loopdevice")
if [ $? -ne 0 ]; then
    echo "错误：无法映射镜像分区。退出。" ; exit 1;
fi
# 从 kpartx 输出中解析设备映射名称，例如 loop0p1, loop0p2
partBoot="/dev/mapper/${device_mapper_name}p1"
partRoot="/dev/mapper/${device_mapper_name}p2"

# 再次检查映射设备是否存在
if [ ! -b "$partBoot" ] || [ ! -b "$partRoot" ]; then
    echo "错误：映射分区 $partBoot 或 $partRoot 不存在。kpartx 可能失败。"
    exit 1
fi

echo "新镜像分区：引导 -> $partBoot, 根 -> $partRoot"

# 等待设备映射创建完成
sleep 2s

# 格式化引导分区
echo "正在格式化引导分区 $partBoot..."
mkfs.vfat -F 32 -n "boot" "$partBoot" # 重新格式化并设置一个标签
if [ $? -ne 0 ]; then echo "错误：格式化引导分区失败。退出。" ; exit 1; fi

# 格式化根分区
echo "正在格式化根分区 $partRoot..."
mkfs.ext4 -F "$partRoot"
if [ $? -ne 0 ]; then echo "错误：格式化根分区失败。退出。" ; exit 1; fi
e2label "$partRoot" "rootfs" # 设置一个标签，你可以根据需要修改

# --- 复制数据 ---
echo "--- 阶段 7/8: 复制数据到新镜像 ---"
# 挂载新镜像的引导分区
mkdir -p /mnt/boot_temp
mount -t "$BOOT_FSTYPE" "$partBoot" /mnt/boot_temp
if [ $? -ne 0 ]; then echo "错误：挂载新镜像引导分区失败。退出。" ; exit 1; fi

# 复制引导分区内容
echo "复制引导分区内容..."
# 确保源目录存在且可读
if [ ! -d "$BOOT_MOUNTPOINT" ] || [ ! -r "$BOOT_MOUNTPOINT" ]; then
    echo "错误：原始引导分区挂载点 $BOOT_MOUNTPOINT 不存在或不可读。退出。"
    exit 1
fi
cp -rfp "${BOOT_MOUNTPOINT}"/* /mnt/boot_temp/
if [ $? -ne 0 ]; then echo "错误：复制引导分区内容失败。退出。" ; fi

# 获取新的分区 PARTUUIDs
NEW_BOOT_PARTUUID=$(blkid -o export "$partBoot" | grep PARTUUID)
NEW_ROOT_PARTUUID=$(blkid -o export "$partRoot" | grep PARTUUID)

# 更新 cmdline.txt 中的根分区 PARTUUID
echo "更新 /mnt/boot_temp/cmdline.txt 中的 PARTUUID..."
# 检查 cmdline.txt 是否存在且可写
if [ -f "/mnt/boot_temp/cmdline.txt" ] && [ -w "/mnt/boot_temp/cmdline.txt" ]; then
    sed -i "s/${ORIG_ROOT_PARTUUID}/${NEW_ROOT_PARTUUID}/g" /mnt/boot_temp/cmdline.txt
    if [ $? -ne 0 ]; then echo "警告：更新 cmdline.txt 失败。" ; fi
else
    echo "警告：/mnt/boot_temp/cmdline.txt 文件不存在或不可写，跳过 PARTUUID 更新。"
fi

sync # 确保数据写入磁盘

umount /mnt/boot_temp
rmdir /mnt/boot_temp
echo "已卸载新镜像引导分区。"

# 挂载新镜像的根分区
mkdir -p /mnt/root_temp
mount -t "$ROOT_FSTYPE" "$partRoot" /mnt/root_temp
if [ $? -ne 0 ]; then echo "错误：挂载新镜像根分区失败。退出。" ; fi

# 排除 swapfile (如果存在)
EXCLUDE_SWAPFILE=""
if [ -f /etc/dphys-swapfile ]; then
    SWAPFILE_PATH=$(grep "^CONF_SWAPFILE=" /etc/dphys-swapfile | cut -d'=' -f2)
    if [ -z "$SWAPFILE_PATH" ]; then
        SWAPFILE_PATH="/var/swap" # 默认值
    fi
    EXCLUDE_SWAPFILE="--exclude $SWAPFILE_PATH"
    echo "将排除 swapfile: $SWAPFILE_PATH"
fi

# 复制根文件系统内容
echo "复制根文件系统内容 (可能需要较长时间)..."
# 注意：rsync 的源是 / (根目录)，目标是 /mnt/root_temp/
rsync --force -rltWDEgop --delete --stats --progress \
    $EXCLUDE_SWAPFILE \
    --exclude "/dev/*" \
    --exclude "/proc/*" \
    --exclude "/sys/*" \
    --exclude "/run/*" \
    --exclude "/mnt/*" \
    --exclude "/media/*" \
    --exclude "/tmp/*" \
    --exclude "/boot/*" \
    --exclude "/lost+found" \
    --exclude "${BACKUP_DIR}/*" \
    --exclude "$(pwd)/*" \
    / /mnt/root_temp/
if [ $? -ne 0 ]; then echo "错误：复制根文件系统失败。退出。" ; fi

# 创建必要的空目录 (rsync --exclude 它们后需要重建，以便下次启动时能正确挂载虚拟文件系统)
echo "创建必要的空目录..."
for dir in dev proc sys run media mnt boot tmp; do
    if [ ! -d "/mnt/root_temp/$dir" ]; then
        mkdir "/mnt/root_temp/$dir"
    fi
done
# /tmp 权限
chmod a+w /mnt/root_temp/tmp

# 更新 /etc/fstab 中的 PARTUUIDs
echo "更新 /mnt/root_temp/etc/fstab 中的 PARTUUIDs..."
# 检查 fstab 是否存在且可写
if [ -f "/mnt/root_temp/etc/fstab" ] && [ -w "/mnt/root_temp/etc/fstab" ]; then
    sed -i "s/${ORIG_BOOT_PARTUUID}/${NEW_BOOT_PARTUUID}/g" /mnt/root_temp/etc/fstab
    sed -i "s/${ORIG_ROOT_PARTUUID}/${NEW_ROOT_PARTUUID}/g" /mnt/root_temp/etc/fstab
    if [ $? -ne 0 ]; then echo "警告：更新 fstab 失败。" ; fi
else
    echo "警告：/mnt/root_temp/etc/fstab 文件不存在或不可写，跳过 PARTUUID 更新。"
fi

sync # 确保所有数据写入磁盘

umount /mnt/root_temp
rmdir /mnt/root_temp
echo "已卸载新镜像根分区。"

echo "--- 阶段 8/8: 备份完成 ---"
echo "系统盘备份镜像文件已成功创建到："
echo "$DEST_IMG_PATH"
echo "您现在可以使用 Raspberry Pi Imager 等工具将此镜像写入新的 SD 卡或 USB 启动盘。"
