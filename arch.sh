#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
	echo "Please run this script as root."
	exit 1
fi

# Test network connectivity
echo "Testing network connectivity..."
ping -c 3 www.archlinux.org &>/dev/null
if [ $? -ne 0 ]; then
	echo "Network connection failed, please check your network and rerun the script."
	exit 1
fi

# Automatically detect or interactively select a disk
select_disk() {
	echo "The following disks were detected:"
	lsblk -d -o NAME,SIZE,TYPE | grep disk

	# Check if /dev/sda exists (since it's your VM's disk)
	DISK="/dev/sda"
	if [ -b "$DISK" ]; then
		echo "Automatically selected disk: $DISK"
	else
		# If no /dev/sda, prompt user to input the disk name
		while true; do
			read -rp "Please enter the target disk (e.g., /dev/sda): " DISK
			if [ -b "$DISK" ]; then
				echo "Selected disk: $DISK"
				break
			else
				echo "Invalid disk, please try again."
			fi
		done
	fi
}

select_disk
EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
SWAP_PART="${DISK}3"

# Configuration variables
HOSTNAME="archlinux"
USERNAME="user"
PASSWORD="password" # Change to actual user password
TIMEZONE="Asia/Shanghai"
LOCALE="en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8"
LANG="en_US.UTF-8"

# Synchronize system time
echo "Synchronizing system time..."
timedatectl set-ntp true

# Partition the disk
echo "Partitioning the disk..."
parted $DISK mklabel gpt
parted $DISK mkpart primary fat32 1MiB 513MiB
parted $DISK set 1 esp on
parted $DISK mkpart primary linux-swap 513MiB 4GiB
parted $DISK mkpart primary ext4 4GiB 100%

# Format partitions
echo "Formatting partitions..."
mkfs.fat -F32 $EFI_PART
mkswap $SWAP_PART
swapon $SWAP_PART
mkfs.btrfs $ROOT_PART

# Mount partitions
echo "Mounting partitions..."
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@,compress=zstd $ROOT_PART /mnt
mkdir /mnt/home
mount -o subvol=@home,compress=zstd $ROOT_PART /mnt/home
mkdir -p /mnt/boot
mount $EFI_PART /mnt/boot

# Install basic system
echo "Installing base system..."
pacstrap /mnt base base-devel linux linux-firmware btrfs-progs

# Generate fstab file
echo "Generating fstab file..."
genfstab -U /mnt >/mnt/etc/fstab

# Chroot into the new system
echo "Chrooting into the new system..."
arch-chroot /mnt /bin/bash <<EOF

# Set timezone
echo "Setting timezone..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set Locale
echo "Setting Locale..."
echo -e "$LOCALE" > /etc/locale.gen
locale-gen
echo "LANG=$LANG" > /etc/locale.conf

# Set hostname
echo "Setting hostname..."
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t$HOSTNAME.localdomain\t$HOSTNAME" > /etc/hosts

# Set root password
echo "Setting root password..."
echo "root:$PASSWORD" | chpasswd

# Create regular user
echo "Creating user..."
useradd -m -G wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Install bootloader
echo "Installing bootloader..."
pacman -S --noconfirm grub efibootmgr os-prober intel-ucode amd-ucode

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# Enable necessary services
echo "Enabling necessary services..."
systemctl enable NetworkManager
EOF

# Unmount partitions
echo "Unmounting partitions..."
umount -R /mnt
swapoff $SWAP_PART

echo "Installation complete, reboot to enter the system."
