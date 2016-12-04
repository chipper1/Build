#!/bin/sh

while getopts ":v:p:" opt; do
  case $opt in
    v)
      VERSION=$OPTARG
      ;;
    p)
      PATCH=$OPTARG
      ;;

  esac
done

BUILDDATE=$(date -I)
IMG_FILE="Volumio${VERSION}-${BUILDDATE}-bananapi-m2u.img"


echo "Creating Image File"
echo "Image file: ${IMG_FILE}"
dd if=/dev/zero of=${IMG_FILE} bs=1M count=1700

echo "Creating Image Bed"
LOOP_DEV=`sudo losetup -f --show ${IMG_FILE}`
# Note: leave the first 20Mb free for the firmware
sudo parted -s "${LOOP_DEV}" mklabel msdos
sudo parted -s "${LOOP_DEV}" mkpart primary fat32 105 172
sudo parted -s "${LOOP_DEV}" mkpart primary ext3 172 1650
sudo parted -s "${LOOP_DEV}" mkpart primary ext3 1650 100%
sudo parted -s "${LOOP_DEV}" set 1 boot on
sudo parted -s "${LOOP_DEV}" print
sudo partprobe "${LOOP_DEV}"
sudo kpartx -s -a "${LOOP_DEV}"

BOOT_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p1`
SYS_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p2`
DATA_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p3`
echo "Using: " ${BOOT_PART}
echo "Using: " ${SYS_PART}
echo "Using: " ${DATA_PART}
if [ ! -b "${BOOT_PART}" ]
then
	echo "${BOOT_PART} doesn't exist"
	exit 1
fi

echo "Creating boot and rootfs filesystems"
sudo mkfs -t vfat -n BOOT "${BOOT_PART}"
sudo mkfs -F -t ext4 -L volumio "${SYS_PART}"
sudo mkfs -F -t ext4 -L volumio_data "${DATA_PART}"
sync

echo "Preparing for the banana bpi-m2u kernel/ platform files"
if [ -d platform-banana ]
then 
	echo "Platform folder already exists - keeping it"
    # if you really want to re-clone from the repo, then delete the platform-banana folder
    # that will refresh all the bananapi platforms, see below
else
	echo "Clone bananapi m2u files from repo"
	git clone https://github.com/gkkpch/platform-banana.git platform-banana
	echo "Unpack the platform files"
    cd platform-banana
	tar xfJ bpi-m2u.tar.xz
	cd ..
fi

echo "Copying the bootloader"
sudo dd if=platform-banana/bpi-m2u/uboot/boot0_sdcard.fex of=${LOOP_DEV} conv=notrunc bs=1k seek=8
sudo dd if=platform-banana/bpi-m2u/uboot/boot_package.fex of=${LOOP_DEV} conv=notrunc bs=1k seek=16400
sudo dd if=platform-banana/bpi-m2u/uboot/sunxi_mbr.fex of=${LOOP_DEV} conv=notrunc bs=1k seek=20480
sudo dd if=platform-banana/bpi-m2u/uboot/boot-resource.fex of=${LOOP_DEV} conv=notrunc bs=1k seek=36864
sudo dd if=platform-banana/bpi-m2u/uboot/env.fex of=${LOOP_DEV} conv=notrunc bs=1k seek=53248

sync

echo "Preparing for Volumio rootfs"
if [ -d /mnt ]
then 
	echo "/mount folder exist"
else
	sudo mkdir /mnt
fi
if [ -d /mnt/volumio ]
then 
	echo "Volumio Temp Directory Exists - Cleaning it"
	rm -rf /mnt/volumio/*
else
	echo "Creating Volumio Temp Directory"
	sudo mkdir /mnt/volumio
fi

echo "Creating mount point for the images partition"
mkdir /mnt/volumio/images
sudo mount -t ext4 "${SYS_PART}" /mnt/volumio/images
sudo mkdir /mnt/volumio/rootfs
echo "Creating mount point for the boot partition"
sudo mkdir /mnt/volumio/rootfs/boot
sudo mount -t vfat "${BOOT_PART}" /mnt/volumio/rootfs/boot

echo "Copying Volumio RootFs"
sudo cp -pdR build/arm/root/* /mnt/volumio/rootfs
echo "Copying BPI-M2U boot files"
mkdir -p /mnt/volumio/rootfs/boot/bananapi
mkdir -p /mnt/volumio/rootfs/boot/bananapi/bpi-m2u
mkdir -p /mnt/volumio/rootfs/boot/bananapi/bpi-m2u/linux
sudo cp platform-banana/bpi-m2u/boot/uImage /mnt/volumio/rootfs/boot/bananapi/bpi-m2u/linux
sudo cp platform-banana/bpi-m2u/boot/uEnv.txt /mnt/volumio/rootfs/boot/bananapi/bpi-m2u/linux
sudo cp platform-banana/bpi-m2u/boot/Image.version /mnt/volumio/rootfs/boot/
sudo cp platform-banana/bpi-m2u/boot/config* /mnt/volumio/rootfs/boot/

echo "Copying BPI-M2U modules and firmware"
sudo cp -pdR platform-banana/bpi-m2u/lib/modules /mnt/volumio/rootfs/lib/
sudo cp -pdR platform-banana/bpi-m2u/lib/firmware /mnt/volumio/rootfs/lib/


#TODO: bananapi's should be able to run generic debian
#sed -i "s/Raspbian/Debian/g" /mnt/volumio/rootfs/etc/issue

sync

echo "Preparing to run chroot for more BPI-M2U configuration"
cp scripts/bpim2uconfig.sh /mnt/volumio/rootfs
cp scripts/initramfs/init /mnt/volumio/rootfs/root
cp scripts/initramfs/mkinitramfs-custom.sh /mnt/volumio/rootfs/usr/local/sbin
#copy the scripts for updating from usb
wget -P /mnt/volumio/rootfs/root http://repo.volumio.org/Volumio2/Binaries/volumio-init-updater

mount /dev /mnt/volumio/rootfs/dev -o bind
mount /proc /mnt/volumio/rootfs/proc -t proc
mount /sys /mnt/volumio/rootfs/sys -t sysfs
echo $PATCH > /mnt/volumio/rootfs/patch

chroot /mnt/volumio/rootfs /bin/bash -x <<'EOF'
su -
/bpim2uconfig.sh
EOF

echo "Moving uInitrd to where the kernel is"
sudo mv /mnt/volumio/rootfs/boot/uInitrd /mnt/volumio/rootfs/boot/bananapi/bpi-m2u/linux/uInitrd
#cleanup
rm /mnt/volumio/rootfs/bpim2uconfig.sh /mnt/volumio/rootfs/root/init

echo "Unmounting Temp devices"
umount -l /mnt/volumio/rootfs/dev 
umount -l /mnt/volumio/rootfs/proc 
umount -l /mnt/volumio/rootfs/sys 

#echo "Copying LIRC configuration files"


echo "==> BPI-M2U device installed"  

#echo "Removing temporary platform files"
#echo "(you can keep it safely as long as you're sure of no changes)"
#sudo rm -r platform-bananapi
sync

echo "Preparing rootfs base for SquashFS"

if [ -d /mnt/squash ]; then
	echo "Volumio SquashFS Temp Dir Exists - Cleaning it"
	rm -rf /mnt/squash/*
else
	echo "Creating Volumio SquashFS Temp Dir"
	sudo mkdir /mnt/squash
fi

echo "Copying Volumio rootfs to Temp Dir"
cp -rp /mnt/volumio/rootfs/* /mnt/squash/

echo "Removing the Kernel"
rm -rf /mnt/squash/boot/*

echo "Creating SquashFS, removing any previous one"
rm -r Volumio.sqsh
mksquashfs /mnt/squash/* Volumio.sqsh

echo "Squash filesystem created"
echo "Cleaning squash environment"
rm -rf /mnt/squash

#copy the squash image inside the boot partition
cp Volumio.sqsh /mnt/volumio/images/volumio_current.sqsh
sync
echo "Unmounting Temp Devices"
sudo umount -l /mnt/volumio/images
sudo umount -l /mnt/volumio/rootfs/boot

echo "Cleaning build environment"
rm -rf /mnt/volumio /mnt/boot

sudo dmsetup remove_all
sudo losetup -d ${LOOP_DEV}
sync

md5sum "$IMG_FILE" > "${IMG_FILE}.md5"
