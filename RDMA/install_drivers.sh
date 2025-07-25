# workload description: 
# https://docs.google.com/document/d/1H7dHv-ldwS0_ZkDlEpZvuVBcS-XayjBDBpB11y4urNE/edit?resourcekey=0-NJpDHqIGw2KdGmo3HOx6uA&tab=t.0
# https://docs.google.com/document/d/1IzN7rmU1S0X7u82gC8IEN5mRSCjRIxA6kFp5KWPcbQY/edit?tab=t.0
# Inspired by https://github.com/llm-on-gke/create-a3mega/blob/main/startup_script.sh

#!/bin/bash

# Set version variables
set -ex -o pipefail
DRIVER_VERSION=570.158.01
CUDA_VERSION=12.8.0
NCCL_VERSION=2.26.6-1
OS_VERSION="ubuntu$(lsb_release -sr | tr -d '.')"       # assuming running on ubuntu
KERN_VERSION=$(uname -a | awk '{print $3}')
DEBIAN_FRONTEND=noninteractive

# Disable automatic updates and hold packages with known instabilities
# with Debian12 a3-ultragpu-8g VMs
systemctl stop unattended-upgrades.service
systemctl disable unattended-upgrades.service
systemctl mask unattended-upgrades.service
apt-mark hold google-compute-engine
apt-mark hold google-compute-engine-oslogin
apt-mark hold google-guest-agent
apt-mark hold google-osconfig-agent

# Install Pre-requisites
apt-get update -y
apt-get install -y \
  build-essential \
  git \
  python3-venv \
  dkms \
  linux-headers-$(uname -r) \
  linux-headers-generic \
  mdadm \
  ca-certificates \
  curl \
  zlib1g-dev

# Install NVIDIA Drivers
cd /var/tmp/
wget -q https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run
sh NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run --ui=none --no-questions --dkms -m=kernel-open -k ${KERN_VERSION}
rm ./NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run

# Install CUDA toolkit + other utilities
wget https://developer.download.nvidia.com/compute/cuda/repos/${OS_VERSION}/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt install ./cuda-keyring_1.1-1_all.deb
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg  && \
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update -y
apt install -y \
  nvidia-compute-utils-570-server \
  cuda-toolkit-12-8 \
  libnvidia-nscq-570 \
  nvidia-container-toolkit \
  nvidia-fabricmanager-570 \
  datacenter-gpu-manager
  # nvidia-cfg1-570-server \
systemctl --now enable nvidia-dcgm
export PATH=${PATH}:/usr/local/cuda/bin
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/usr/local/cuda/lib64

# Install ibverbs + MST
apt install -y ibverbs-utils dkms gcc-12
mkdir -p /opt/src && cd /opt/src
wget https://www.mellanox.com/downloads/MFT/mft-4.31.0-149-x86_64-deb.tgz
tar -xvf mft-4.31.0-149-x86_64-deb.tgz
cd mft-4.31.0-149-x86_64-deb
./install.sh
rm -rf mft*

# Install Mellanox DOCA-OFED
# Follow https://developer.nvidia.com/doca-downloads?deployment_platform=Host-Server&deployment_package=DOCA-Host&target_os=Linux&Architecture=x86_64&Profile=doca-ofed&Distribution=Ubuntu&version=22.04&installer_type=deb_online
export DOCA_URL="https://linux.mellanox.com/public/repo/doca/2.10.0/ubuntu22.04/x86_64/"
curl https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub | gpg --dearmor > /etc/apt/trusted.gpg.d/GPG-KEY-Mellanox.pub
echo "deb [signed-by=/etc/apt/trusted.gpg.d/GPG-KEY-Mellanox.pub] $DOCA_URL ./" > /etc/apt/sources.list.d/doca.list
apt update -y
apt install -y doca-ofed ucx

# Increase limits (useful for some communication patterns / larger node counts)
mkdir -p /etc/security/limits.d/
cat > /etc/security/limits.d/99-unlimited.conf << 'EOF'
* - memlock unlimited
* - nproc unlimited
* - stack unlimited
* - nofile 1048576
* - cpu unlimited
* - rtprio unlimited
EOF

# Install NCCL/gIB packages
curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg | gpg --dearmor -o \
     /etc/apt/trusted.gpg.d/google-artifact-registry.gpg

curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o \
     /etc/apt/trusted.gpg.d/google-cloud-packages.gpg

echo 'deb http://packages.cloud.google.com/apt apt-transport-artifact-registry-stable main' | \
  tee -a /etc/apt/sources.list.d/artifact-registry.list
apt update -y
apt install -y apt-transport-artifact-registry

echo 'deb ar+https://us-apt.pkg.dev/projects/gce-ai-infra gpudirect-gib-apt main' | \
  tee -a  /etc/apt/sources.list.d/artifact-registry.list

apt update -y
apt install -y nccl-gib

# (Optional) Create a RAID0 of all the local ssd devices
cat > /usr/local/mount_localssd.sh << 'EOF'
#!/bin/bash
set -e -o pipefail

RAID_DEVICE=/dev/md0
DST_MNT=/mnt/localssd
DISK_LABEL=LOCALSSD
OPTIONS=discard,defaults

# if mount is successful, do nothing
if mount --source LABEL="$DISK_LABEL" --target="$DST_MNT" -o "$OPTIONS"; then
        exit 0
fi

# Create new RAID, format ext4 and mount
# TODO: handle case of zero or 1 local SSD disk
# TODO: handle case when /dev/md0 exists but was not mountable for
# some reason
DEVICES=`nvme list | grep nvme_ | grep -v nvme_card-pd | awk '{print $1}' | paste -sd ' '`
NB_DEVICES=`nvme list | grep nvme_ | grep -v nvme_card-pd | awk '{print $1}' | wc -l`
mdadm --create "$RAID_DEVICE" --level=0 --raid-devices=$NB_DEVICES $DEVICES
mkfs.ext4 -F "$RAID_DEVICE"
tune2fs "$RAID_DEVICE" -r 131072
e2label "$RAID_DEVICE" "$DISK_LABEL"
mkdir -p "$DST_MNT"
mount --source LABEL="$DISK_LABEL" --target="$DST_MNT" -o "$OPTIONS"
chmod 1777 "$DST_MNT"
EOF

# (Optional) Create systemd service to RAID0 the local ssd
cat > /etc/systemd/system/mount-local-ssd.service << EOF
[Unit]
Description=Assemble local SSDs as software RAID; then format and mount

[Service]
# ExecCondition=bash -c '/usr/bin/curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-ultragpu-8g$"'
ExecStart=/bin/bash /usr/local/mount_localssd.sh
RemainAfterExit=true
Type=oneshot

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable mount-local-ssd.service

# (Optional) Install openmpi, NCCL, nccl-tests
mkdir -p /opt/src
cd /opt/src
wget https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.7.tar.bz2
tar -xvf openmpi-5.0.7.tar.bz2
cd openmpi-5.0.7
./configure --with-cuda=/usr/local/cuda/targets/x86_64-linux
make -j
make install
echo '/usr/local/lib' | sudo tee /etc/ld.so.conf.d/openmpi.conf
/usr/sbin/ldconfig
cd ../
rm -rf openmpi*

#mkdir -p /opt/src
#cd /opt/src
#git clone -b v${NCCL_VERSION} https://github.com/NVIDIA/nccl.git
#cd /opt/src/nccl
#make -j src.build NVCC_GENCODE="-gencode=arch=compute_100,code=sm_100" #use 100 for B200, 90 for H200   
#make install

apt-get install libnccl-dev libnccl2

mkdir -p /opt/src
cd /opt/src
git clone https://github.com/NVIDIA/nccl-tests.git
cd /opt/src/nccl-tests
MPI=1 CC=mpicc CXX=mpicxx make -j

# run ldconfig near the end
/usr/sbin/ldconfig

echo "Installationsu of gIB + CUDA + NVIDIA Drivers Components Completed"
