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
    # 解挂载 /mnt
    if mountpoint -q /mnt; then
        umount /mnt
        echo "已卸载 /mnt。"
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

# --- 获取 SD 卡和分区信息 ---
echo "--- 阶段 3/8: 获取 SD 卡和分区信息 ---"
SD_DEVICE="/dev/mmcblk0"
BOOT_PART="${SD_DEVICE}p1"
ROOT_PART="${SD_DEVICE}p2"

# 检查 SD 卡设备是否存在
if [ ! -b "$SD_DEVICE" ]; then
    echo "错误：SD 卡设备 $SD_DEVICE 不存在。请确认设备名称是否正确。"
    exit 1
fi

# 获取分区详细信息 (使用 lsblk 的 JSON 输出)
PART_INFO=$(lsblk -o NAME,PARTUUID,FSTYPE,MOUNTPOINTS,SIZE,UUID "${SD_DEVICE}" -J)
if [ $? -ne 0 ]; then
    echo "错误：无法获取设备 $SD_DEVICE 的分区信息。请检查 lsblk 和 jq 是否正常工作。"
    exit 1
fi

# 从 JSON 输出中解析所需信息
BOOT_MOUNTPOINT=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$BOOT_PART")\") | .mountpoints[0]")
ORIG_BOOT_PARTUUID=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$BOOT_PART")\") | .partuuid")
ORIG_ROOT_PARTUUID=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$ROOT_PART")\") | .partuuid")
BOOT_FSTYPE=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$BOOT_PART")\") | .fstype")
ROOT_FSTYPE=$(echo "$PART_INFO" | jq -r ".blockdevices[] | select(.name == \"$(basename "$ROOT_PART")\") | .fstype")

SD_CARD_TOTAL_BYTES=$(blockdev --getsize64 "$SD_DEVICE") # 获取 SD 卡总字节数
if [ $? -ne 0 ]; then
    echo "警告：无法获取 SD 卡总大小。将使用默认方法估算镜像大小。"
    # 如果 blockdev 失败，回退到旧的估算方法
    ROOT_USED_SIZE_KB=$(df -P / | tail -n 1 | awk '{print $3}') # 已用空间
    BOOT_SIZE_KB=$(df -P "$BOOT_MOUNTPOINT" | tail -n 1 | awk '{print $2}') # 引导分区总大小
    # 估算镜像大小：根分区已用 + 引导分区总大小 + 20% 余量
    IMAGE_SIZE_KB=$(((ROOT_USED_SIZE_KB + BOOT_SIZE_KB) * 12 / 10))
else
    # 镜像大小设置为 SD 卡总大小，并增加少量余量以确保兼容性
    # 增加 100MB 作为一个安全边际，以弥补分区表或文件系统开销
    RESERVED_BYTES=$((100 * 1024 * 1024))
    IMAGE_SIZE_KB=$(((SD_CARD_TOTAL_BYTES + RESERVED_BYTES) / 1024))
fi


if [ -z "$BOOT_MOUNTPOINT" ] || [ -z "$ORIG_BOOT_PARTUUID" ] || [ -z "$ORIG_ROOT_PARTUUID" ]; then
    echo "错误：无法获取 SD 卡的关键分区信息。请检查 SD 卡是否正确识别和挂载。"
    exit 1
fi

echo "SD 卡设备: $SD_DEVICE"
echo "引导分区挂载点: $BOOT_MOUNTPOINT (PARTUUID: $ORIG_BOOT_PARTUUID)"
echo "根分区 PARTUUID: $ORIG_ROOT_PARTUUID"
echo "估算镜像大小: $((IMAGE_SIZE_KB / 1024)) MB"

# --- 确认继续 ---
read -p "请确认以上信息无误，即将创建SD卡备份镜像文件。(y/N): " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "备份已取消。"
    exit 0
fi

# --- 创建空的镜像文件 ---
echo "--- 阶段 4/8: 创建空的镜像文件 ---"
IMAGE_FILE_NAME="rpi-$(date +%Y%m%d%H%M%S).img"
DEST_IMG_PATH="${BACKUP_DIR}/${IMAGE_FILE_NAME}"

echo "正在创建镜像文件：$DEST_IMG_PATH (大小约为 $((IMAGE_SIZE_KB / 1024)) MB)..."
# 使用 seek 参数快速创建指定大小的稀疏文件
dd if=/dev/zero of="$DEST_IMG_PATH" bs=1K count=0 seek="$IMAGE_SIZE_KB" status=progress
if [ $? -ne 0 ]; then echo "错误：创建镜像文件失败。退出。" ; exit 1; fi

# --- 在镜像文件中创建分区表 ---
echo "--- 阶段 5/8: 在镜像中创建分区表 ---"
# 获取原始分区的起始和结束扇区，以便在新镜像中精确复制
# 注意：parted 的 mkpart 命令可以直接使用 "start_sector_s" 和 "end_sector_s"
# 或者使用百分比、MB/GB 单位，这里我们使用原始扇区转换为字节，更精确。
PARTED_INFO=$(fdisk -l "$SD_DEVICE" | grep "${SD_DEVICE}p")
BOOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "${SD_DEVICE}p1" | awk '{print $2}')
BOOT_END_SECTOR=$(echo "$PARTED_INFO" | grep "${SD_DEVICE}p1" | awk '{print $3}')
ROOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "${SD_DEVICE}p2" | awk '{print $2}')
ROOT_END_SECTOR=$(echo "$PARTED_INFO" | grep "${SD_DEVICE}p2" | awk '{print $3}') # 根分区通常到最后一个扇区

# 假设扇区大小是 512 字节，实际应从 fdisk -l "Units: sectors of 512 bytes" 中获取
# 简化处理，直接使用扇区数 + 's' 后缀给 parted
BOOT_START_PARTED="${BOOT_START_SECTOR}s"
BOOT_END_PARTED="${BOOT_END_SECTOR}s"
ROOT_START_PARTED="${ROOT_START_SECTOR}s"
# ROOT_END_PARTED="${ROOT_END_SECTOR}s" # 如果要精确到原始结束扇区
# 通常根分区会扩展到剩余所有空间
ROOT_END_PARTED="100%"

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
kpartx_output=$(kpartx -va "$loopdevice")
if [ $? -ne 0 ]; then
    echo "错误：无法映射镜像分区。退出。" ; exit 1;
fi
# 从 kpartx 输出中解析设备映射名称，例如 loop0p1, loop0p2
partBoot="/dev/mapper/${device_mapper_name}p1"
partRoot="/dev/mapper/${device_mapper_name}p2"

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
cp -rfp "${BOOT_MOUNTPOINT}"/* /mnt/boot_temp/
if [ $? -ne 0 ]; then echo "错误：复制引导分区内容失败。退出。" ; exit 1; fi

# 获取新的分区 PARTUUIDs
NEW_BOOT_PARTUUID=$(blkid -o export "$partBoot" | grep PARTUUID)
NEW_ROOT_PARTUUID=$(blkid -o export "$partRoot" | grep PARTUUID)

# 更新 cmdline.txt 中的根分区 PARTUUID
echo "更新 /mnt/boot_temp/cmdline.txt 中的 PARTUUID..."
sed -i "s/${ORIG_ROOT_PARTUUID}/${NEW_ROOT_PARTUUID}/g" /mnt/boot_temp/cmdline.txt
if [ $? -ne 0 ]; then echo "警告：更新 cmdline.txt 失败。" ; fi

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
sed -i "s/${ORIG_BOOT_PARTUUID}/${NEW_BOOT_PARTUUID}/g" /mnt/root_temp/etc/fstab
sed -i "s/${ORIG_ROOT_PARTUUID}/${NEW_ROOT_PARTUUID}/g" /mnt/root_temp/etc/fstab
if [ $? -ne 0 ]; then echo "警告：更新 fstab 失败。" ; fi

sync # 确保所有数据写入磁盘

umount /mnt/root_temp
rmdir /mnt/root_temp
echo "已卸载新镜像根分区。"

echo "--- 阶段 8/8: 备份完成 ---"
echo "SD 卡备份镜像文件已成功创建到："
echo "$DEST_IMG_PATH"
echo "您现在可以使用 Raspberry Pi Imager 等工具将此镜像写入新的 SD 卡。"
