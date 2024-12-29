#!/bin/bash

# 确保脚本以 root 身份运行
if [ "$EUID" -ne 0 ]; then
	echo "请以 root 身份运行此脚本"
	exit 1
fi

# 测试网络连通性
echo "测试网络连通性..."
ping -c 3 www.archlinux.org &>/dev/null
if [ $? -ne 0 ]; then
	echo "网络连接失败，请检查网络后重新运行脚本。"
	exit 1
fi

# 自动检测磁盘或交互式选择磁盘
select_disk() {
	echo "检测到以下磁盘："
	lsblk -d -o NAME,SIZE,TYPE | grep disk

	while true; do
		read -rp "请输入目标磁盘 (如 /dev/sda): " DISK
		if [ -b "$DISK" ]; then
			echo "选择的磁盘是: $DISK"
			break
		else
			echo "无效的磁盘，请重新输入。"
		fi
	done
}

select_disk
EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
SWAP_PART="${DISK}3"

# 配置变量
HOSTNAME="archlinux"
USERNAME="user"
PASSWORD="password" # 修改为实际用户密码
TIMEZONE="Asia/Shanghai"
LOCALE="en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8"
LANG="en_US.UTF-8"

# 更新系统时间
echo "同步系统时间..."
timedatectl set-ntp true

# 分区磁盘
echo "分区磁盘..."
parted $DISK mklabel gpt
parted $DISK mkpart primary fat32 1MiB 513MiB
parted $DISK set 1 esp on
parted $DISK mkpart primary linux-swap 513MiB 4GiB
parted $DISK mkpart primary ext4 4GiB 100%

# 格式化分区
echo "格式化分区..."
mkfs.fat -F32 $EFI_PART
mkswap $SWAP_PART
swapon $SWAP_PART
mkfs.btrfs $ROOT_PART

# 挂载分区
echo "挂载分区..."
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@,compress=zstd $ROOT_PART /mnt
mkdir /mnt/home
mount -o subvol=@home,compress=zstd $ROOT_PART /mnt/home
mkdir -p /mnt/boot
mount $EFI_PART /mnt/boot

# 安装基本系统
echo "安装基本系统..."
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs

# 生成 fstab 文件
echo "生成 fstab 文件..."
genfstab -U /mnt >/mnt/etc/fstab

# 切换到新系统
echo "切换到新系统..."
arch-chroot /mnt /bin/bash <<EOF

# 设置时区
echo "设置时区..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# 设置 Locale
echo "设置 Locale..."
echo -e "$LOCALE" > /etc/locale.gen
locale-gen
echo "LANG=$LANG" > /etc/locale.conf

# 设置主机名
echo "设置主机名..."
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t$HOSTNAME.localdomain\t$HOSTNAME" > /etc/hosts

# 设置 root 密码
echo "设置 root 密码..."
echo "root:$PASSWORD" | chpasswd

# 创建普通用户
echo "创建用户..."
useradd -m -G wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# 安装引导程序
echo "安装引导程序..."
pacman -S --noconfirm grub efibootmgr os-prober intel-ucode amd-ucode

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# 启用必要服务
echo "启用必要服务..."
systemctl enable NetworkManager
EOF

# 卸载分区
echo "卸载分区..."
umount -R /mnt
swapoff $SWAP_PART

echo "安装完成，重启后进入系统。"
