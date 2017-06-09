#!/bin/bash -ex

CentOSInstallationVersion=7
WorkDir=`pwd`
UsbDir=${WorkDir}/usb
iNuDir=${WorkDir}/inu-docker-compose

# Download CentOS iso
curl http://isoredirect.centos.org/centos/${CentOSInstallationVersion}/isos/x86_64/ | grep -v 'isu.edu' > /tmp/tempfile.txt
CentOSURL=`cat /tmp/tempfile.txt | sed -n 's#.*\(http://.*/isos/x86_64/\).*#\1#p' | head -n 1`
curl $CentOSURL > /tmp/tempfile.txt
FileName=`cat /tmp/tempfile.txt | sed -n '/CentOS-.*-x86_64-DVD.*.iso/s/.*\(CentOS-.*-x86_64-DVD.*.iso\).*/\1/p'`
wget -c -P /root ${CentOSURL}${FileName}

if [ "$FileName" == "" ]; then
    exit 1
fi

# Partition USB storage
UsbDevice=/dev/`lsblk -Sn | grep usb | awk '{print $1}'`
if findmnt ${UsbDevice}1; then
    umount -l usb/{BOOT,DATA,IMAGE}
    if findmnt usb/DVD; then
        umount -l usb/DVD
    fi
fi

parted $UsbDevice --script -- mklabel msdos
parted $UsbDevice --script mkpart primary fat32 0% 250MB
parted $UsbDevice --script toggle 1 boot
parted $UsbDevice --script mkpart primary ext3 250MB 8G
parted $UsbDevice --script mkpart primary ext3 8G -- -1
partprobe

# Create and mount filesystem
mkfs -t vfat -n "BOOT" ${UsbDevice}1
mkfs -t ext3 -L "DATA" ${UsbDevice}2
mkfs -t ext3 -L "IMAGE" ${UsbDevice}3
dd conv=notrunc bs=440 count=1 if=/usr/share/syslinux/mbr.bin of=$UsbDevice
syslinux ${UsbDevice}1

mkdir -p usb/{BOOT,DATA,IMAGE,DVD}
for i in BOOT DATA IMAGE; do
    mount -L $i usb/$i
done
mount /root/${FileName} usb/DVD

# Install docker-engine
if ! rpm --quiet -q docker-engine; then
    curl -fsSL https://get.docker.com/ | sh
    systemctl start docker
    systemctl enable docker
fi

# Download iNu images
yum install -y git
if [ -d "${iNuDir}/.git" ]; then
    cd $iNuDir
    git pull
else
    git clone ssh://git@rd.grandsys.com:8687/inu/inu-docker-compose.git
    cd $iNuDir
fi
./run.sh -d
cd $WorkDir


# Copy files to USB(BOOT)
cp -a usb/{DVD/isolinux/*,BOOT}
cp -f syslinux/{ks.cfg,syslinux.cfg} usb/BOOT
rm -f BOOT/{grub.cfg,TRANS.TBL,isolinux.bin}

# Copy iso file to USB(DATA)
cp -f /root/$FileName usb/DATA

# Copy files to USB(IMAGE) - iNu docker images
rsync -avz --exclude='.git' ${iNuDir}/ ${UsbDir}/IMAGE/inu-docker-compose/

# docker-compose
mkdir -p usb/IMAGE/tools
curl -L https://github.com/docker/compose/releases/download/1.13.0/docker-compose-`uname -s`-`uname -m` > usb/IMAGE/tools/docker-compose

# Yum repositories
YumRepo=${UsbDir}/IMAGE/yum_repo
yum install -y yum-utils
yum install -y createrepo
mkdir -p usb/IMAGE/yum_repo/{os/x86_64,dockerrepo,updates/x86_64}
docker pull centos:7
docker run --net=host -v ${YumRepo}/updates/x86_64:/tmp/updates/x86_64 -v ${YumRepo}/dockerrepo:/tmp/dockerrepo -v /etc/yum.repos.d:/etc/yum.repos.d --rm -it centos:7 bash -c '(
    yum install -y yum-utils createrepo
    reposync -r updates -p /tmp/updates/x86_64 --norepopath
    createrepo -v /tmp/updates/x86_64
    reposync -r docker-main-repo -p /tmp/dockerrepo --norepopath
    createrepo -v /tmp/dockerrepo
)'

# Umount filesystem
umount usb/*
