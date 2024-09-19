#!/bin/bash

# Set version variables
set -ex -o pipefail
DRIVER_VERSION=550.90.07
CUDA_VERSION=12.4.1
CUDA_BUNDLE=12.4.1_550.54.15
DEBIAN_FRONTEND=noninteractive

# Disable automatic updates and hold packages with known instabilities
# with Debian12 A3-Mega VMs
systemctl stop unattended-upgrades.service
systemctl disable unattended-upgrades.service
systemctl mask unattended-upgrades.service
sudo apt-get purge -y unattended-upgrades

apt-mark hold google-compute-engine
apt-mark hold google-compute-engine-oslogin
apt-mark hold google-guest-agent
apt-mark hold google-osconfig-agent

# Install Pre-requisites
apt-get update -y
apt-get install -y build-essential git python3-venv dkms  linux-headers-$(uname -r) mdadm

# Install GVNIC Driver
cd /var/tmp/
wget -q https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-linux/releases/download/v1.3.4/gve-dkms_1.3.4_all.deb
dpkg -i gve-dkms_1.3.4_all.deb
rm ./gve-dkms_1.3.4_all.deb

# Install NVIDIA Drivers
 wget -q https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run
 sh NVIDIA-Linux-x86_64-550.90.07.run --ui=none --no-questions --dkms -m=kernel-open -k $(uname -r)
 rm ./NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run
#
# # Install CUDA
wget -q https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/cuda_${CUDA_BUNDLE}_linux.run
sh cuda_${CUDA_BUNDLE}_linux.run --toolkit --silent --override
rm cuda_${CUDA_BUNDLE}_linux.run

# Install nvidia container toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -y
apt-get install -y nvidia-container-toolkit

# Patch tab-completion issue in os-login (has been fixed in some recent versions)
cat > /var/tmp/bash_completion.patch << 'EOF'
--- /usr/share/bash-completion/bash_completion
+++ bash_completion
@@ -548,9 +548,9 @@
     elif [[ $1 == \'* ]]; then
         # Leave out first character
         printf -v $2 %s "${1:1}"
-    elif [[ $1 == ~* ]]; then
+    elif [[ $1 == \~* ]]; then
         # avoid escaping first ~
-        printf -v $2 ~%q "${1:1}"
+        printf -v $2 \~%q "${1:1}"
     else
         printf -v $2 %q "$1"
     fi
EOF
# patch -u /usr/share/bash-completion/bash_completion < /var/tmp/bash_completion.patch

# Fix timesyncd
mkdir -p /etc/systemd/system/systemd-timesyncd.service.d/
cat > /etc/systemd/system/systemd-timesyncd.service.d/burst_limit.conf << 'EOF'
[Unit]
# Increase start burst limit to exceed number of network adapters
# in the system (rapid restart 1 per NIC)
StartLimitBurst=10
EOF

# Fix DNS for multi-NIC
cat > /etc/netplan/90-default.yaml << 'EOF'
network:
    version: 2
    ethernets:
        00-primary:
            match:
                name: enp0*
            dhcp4: true
            dhcp4-overrides:
                use-domains: true
            dhcp6: true
            dhcp6-overrides:
                use-domains: true
        90-gpu-nets:
            match:
                name: en*
            dhcp4: true
            dhcp4-overrides:
                use-domains: true
                use-dns: false
                use-ntp: false
            dhcp6: true
            dhcp6-overrides:
                use-domains: true
                use-dns: false
                use-ntp: false
        99-all-eth:
            match:
                name: eth*
            dhcp4: true
            dhcp4-overrides:
                use-domains: true
            dhcp6: true
            dhcp6-overrides:
                use-domains: true
EOF

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

# Install and enable nvidia-persistenced
if id "nvidia-persistenced" > /dev/null 2>&1; then
  echo "nvidia-persistenced user already exists"
else
  echo "creating nvidia-persistenced user"
  useradd -s /sbin/nologin -d '/' -c 'NVIDIA Persistence Daemon' -r nvidia-persistenced
fi

cat > /usr/lib/systemd/system/nvidia-persistenced.service << 'EOF'
[Unit]
Description=NVIDIA Persistence Daemon
Wants=syslog.target

[Service]
Type=forking
ExecCondition=bash -c '/usr/bin/curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced

[Install]
WantedBy=multi-user.target
EOF
set +e
systemctl daemon-reload
systemctl enable nvidia-persistenced
set -e

# Install TCPXO import_helper
echo "Installing TCPXO import_helper"
curl https://us-apt.pkg.dev/doc/repo-signing-key.gpg | sudo apt-key add - && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo 'deb http://packages.cloud.google.com/apt apt-transport-artifact-registry-stable main' | tee -a /etc/apt/sources.list.d/artifact-registry.list
apt-get update -y
apt install -y apt-transport-artifact-registry
echo 'deb [arch=all] ar+https://us-apt.pkg.dev/projects/gce-ai-infra gpudirect-tcpxo-apt main' \
  | tee -a /etc/apt/sources.list.d/artifact-registry.list
apt update -y
apt-get install -y dmabuf-import-helper
echo import-helper > /etc/modules-load.d/import-helper.conf

# Install Aperture Mounting Service
cat > /usr/local/mount_aperture.sh << 'EOF'
#!/bin/bash
MAX_APERTURE_RETRIES=10
aperture_retries=0

until lspci -nn -D | grep -q '1ae0:0084' || [ $aperture_retries -eq $MAX_APERTURE_RETRIES ]; do
  echo "$(date): APERTURE devices not yet fully available (attempt $aperture_retries/$MAX_APERTURE_RETRIES). Retrying in 5 seconds..."
  sleep 5
  aperture_retries=$((aperture_retries + 1))
done

if [ $aperture_retries -eq $MAX_APERTURE_RETRIES ]; then
  echo "$(date): ERROR: APERTURE devices failed to initialize after $MAX_APERTURE_RETRIES retries."
  # Consider taking additional error-handling actions
  exit 0
fi

echo "$(date): Aperture devices ready!"
lspci -nn -D | grep '1ae0:0084' | awk '{print $1}' | xargs --no-run-if-empty -I {} -n 1 mkdir -p /dev/aperture_devices/{}
lspci -nn -D | grep '1ae0:0084' | awk '{print $1}' | xargs --no-run-if-empty -I {} -n 1 umount -f /dev/aperture_devices/{} || true
lspci -nn -D | grep '1ae0:0084' | awk '{print $1}' | xargs --no-run-if-empty -I {} -n 1 mount --bind /sys/bus/pci/devices/{} /dev/aperture_devices/{}
if [ -d /dev/aperture_devices ]; then
    chmod -R a+r /dev/aperture_devices/
    chmod a+rw /dev/aperture_devices/*/resource*
fi
echo "$(date): Aperture devices mounted!"
EOF

cat > /etc/systemd/system/mount-aperture.service << 'EOF'
[Unit]
Description=Mount aperture devices
StartLimitIntervalSec=60
Wants=network-online.target
After=network-online.target

[Service]
ExecCondition=bash -c '/usr/bin/curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/bin/bash /usr/local/mount_aperture.sh

[Install]
WantedBy = multi-user.target
EOF

systemctl daemon-reload
systemctl enable mount-aperture.service
systemctl start mount-aperture

# Install Docker (to run RxDM and install libnccl-net)
# Add Docker's official GPG key:
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

set +e
# TODO: set this via file maybe? asks for input from user, maybe not viable from packer
echo "Y" | gcloud auth configure-docker us-docker.pkg.dev
/usr/bin/docker-credential-gcloud login
NCCL_PLUGIN_IMAGE=us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.4
RXDM_IMAGE=us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.10
RXDM_CONTAINER=receive-datapath-manager
# Pre-pull images
docker pull ${RXDM_IMAGE}
docker pull ${NCCL_PLUGIN_IMAGE}
set -e

# Add script to install libnccl-net
cat > /usr/local/install-ncclnet.sh << EOF
#!/bin/bash

# Install NCCL Net Plugin
# Potentially can remove --pull=always if we have pre-pulled
docker run --rm --gpus all --name nccl-installer --network=host --cap-add=NET_ADMIN \
  --pull=always \
  --volume /var/lib:/var/lib \
  --device /dev/nvidia0:/dev/nvidia0 \
  --device /dev/nvidia1:/dev/nvidia1 \
  --device /dev/nvidia2:/dev/nvidia2 \
  --device /dev/nvidia3:/dev/nvidia3 \
  --device /dev/nvidia4:/dev/nvidia4 \
  --device /dev/nvidia5:/dev/nvidia5 \
  --device /dev/nvidia6:/dev/nvidia6 \
  --device /dev/nvidia7:/dev/nvidia7 \
  --device /dev/nvidia-uvm:/dev/nvidia-uvm \
  --device /dev/nvidiactl:/dev/nvidiactl \
  --device /dev/dmabuf_import_helper:/dev/dmabuf_import_helper \
  --env LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/nvidia/lib64:/var/lib/tcpxo/lib64 \
  ${NCCL_PLUGIN_IMAGE} \
  install

cat >> /var/lib/tcpxo/lib64/nccl-env-profile.sh  << ENVEOF
export NCCL_FASTRAK_CTRL_DEV=enp0s12
export NCCL_FASTRAK_IFNAME=enp6s0,enp7s0,enp13s0,enp14s0,enp134s0,enp135s0,enp141s0,enp142s0
export NCCL_SOCKET_IFNAME=enp0s12
export NCCL_USE_SNAP=1
export NCCL_FASTRAK_USE_LLCM=1
export NCCL_FASTRAK_LLCM_DEVICE_DIRECTORY=/dev/aperture_devices
ENVEOF

EOF

# Create systemd service that installs libnccl-net on startup
cat > /etc/systemd/system/install-nccl-net.service << 'EOF'
[Unit]
Description=Install NCCL Network Library
StartLimitIntervalSec=60
Wants=network-online.target nvidia-persistenced.service
After=network-online.target nvidia-persistenced.service

[Service]
ExecCondition=bash -c '/usr/bin/curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/bin/bash /usr/local/install-ncclnet.sh
RemainAfterExit=true
Type=oneshot

[Install]
WantedBy = multi-user.target
EOF

# Create script that runs the RxDM process.
cat > /usr/local/start-rxdm.sh << EOF
# Start FasTrak receive-datapath-manager
# Potentially can remove --pull=always if we have pre-pulled
docker run \
  --pull=always \
  --rm \
  --name ${RXDM_CONTAINER} \
  --cap-add=NET_ADMIN \
  --network=host \
  --privileged \
  --gpus all \
  --volume /var/lib/nvidia/lib64:/usr/local/nvidia/lib64 \
  --volume /dev/dmabuf_import_helper:/dev/dmabuf_import_helper \
  --env LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu \
  ${RXDM_IMAGE} \
  --num_hops=2 --num_nics=8 --uid= --alsologtostderr
EOF

# Create systemd service that starts RxDM process as a service.
cat > /etc/systemd/system/rxdm.service << EOF
[Unit]
Description=Run TCPXO RxDM Sidecar Container
StartLimitIntervalSec=60
Wants=network-online.target nvidia-persistenced.service
After=network-online.target nvidia-persistenced.service

[Service]
ExecCondition=bash -c '/usr/bin/curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/bin/bash /usr/local/start-rxdm.sh
ExecStopPost=docker container stop ${RXDM_CONTAINER}

[Install]
WantedBy = multi-user.target
EOF

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
ExecCondition=bash -c '/usr/bin/curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/bin/bash /usr/local/mount_localssd.sh
RemainAfterExit=true
Type=oneshot

[Install]
WantedBy=local-fs.target
EOF

systemctl daemon-reload
systemctl enable install-nccl-net.service
systemctl enable rxdm.service
systemctl enable mount-local-ssd.service

# (Optional) Install openmpi, NCCL, nccl-tests
apt-get install -y libopenmpi-dev

mkdir -p /opt/src

cd /opt/src
git clone -b v2.22.3-1 https://github.com/NVIDIA/nccl.git
cd /opt/src/nccl
make -j src.build NVCC_GENCODE="-gencode=arch=compute_90,code=sm_90"
make install

cd /opt/src
git clone https://github.com/NVIDIA/nccl-tests.git
cd /opt/src/nccl-tests
MPI=1 CC=mpicc CXX=mpicxx make -j

echo "Installation of TCPXO Components Completed"
shutdown now
