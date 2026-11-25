#!/bin/bash
# Rocky Linux 8 host setup script for A3 Mega (a3-megagpu-8g) GPUDirect-TCPXO.
#
# Based on:
#   https://docs.cloud.google.com/compute/docs/gpus/gpudirect#rocky
#   Base image: rocky-linux-8-optimized-gcp-nvidia-580 (project: rocky-linux-accelerator-cloud)
#
# Can be used in two modes:
#   1. Image build mode (build_image.sh sets instance metadata build-image=true):
#      Installs all components, pre-pulls containers, installs /var/lib/tcpxo/lib64,
#      enables systemd services, and shuts down the builder VM.
#   2. Direct VM mode (startup script on a3-megagpu-8g or manual `sudo bash startup_script_rocky.sh`):
#      Installs all components and immediately starts mount-aperture.service and rxdm.service.

set -euxo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Allow overriding component versions via GCE instance metadata or environment variables.
get_meta() {
  local key="$1" default_val="${2:-}"
  local val
  val=$(curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key}" 2>/dev/null || true)
  echo "${val:-$default_val}"
}

RXDM_IMAGE="${RXDM_IMAGE:-$(get_meta rxdm-image "us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.21")}"
NCCL_NET_IMAGE="${NCCL_NET_IMAGE:-$(get_meta nccl-net-image "us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.15")}"
NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-$(get_meta nvidia-container-toolkit-version "1.17.8-1")}"
BUILD_IMAGE_MODE="$(get_meta build-image "false")"
MACHINE_TYPE="$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type || true)"

# Ensure we are on Rocky Linux 8 (do NOT run `dnf update` or change the running kernel).
if ! grep -qE '^VERSION_ID="8' /etc/os-release; then
  echo "WARNING: This script is validated for Rocky Linux 8 (rocky-linux-8-optimized-gcp-nvidia-580)."
  echo "Detected OS: $(grep PRETTY_NAME /etc/os-release)"
fi

echo "=== 1. Installing prerequisite packages (keeping kernel $(uname -r) intact) ==="
dnf -y install epel-release dnf-plugins-core "kernel-devel-$(uname -r)" git pciutils mdadm nvme-cli
dnf -y install dkms

echo "=== 2. Building and loading dmabuf import_helper DKMS module ==="
if [[ ! -d /usr/src/import_helper-1.0 ]]; then
  git clone https://github.com/google/dmabuf_importer_helper.git /usr/src/import_helper-1.0
fi
if ! dkms status -m import_helper -v 1.0 -k "$(uname -r)" | grep -q "installed"; then
  dkms install import_helper/1.0 -k "$(uname -r)"
fi
modprobe import_helper
echo "import_helper" > /etc/modules-load.d/import_helper.conf
lsmod | grep import_helper
ls -l /dev/dmabuf_import_helper

echo "=== 3. Installing Docker CE and NVIDIA Container Toolkit ==="
if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
fi
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl --now enable docker

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  -o /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf -y install \
  "nvidia-container-toolkit-${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
  "nvidia-container-toolkit-base-${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
  "libnvidia-container-tools-${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
  "libnvidia-container1-${NVIDIA_CONTAINER_TOOLKIT_VERSION}"

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Configure Artifact Registry authentication for root (used by systemd services and sudo docker).
gcloud auth configure-docker --quiet us-docker.pkg.dev

echo "=== 4. Pre-pulling RxDM and NCCL plugin images & installing /var/lib/tcpxo/lib64 ==="
docker pull "${RXDM_IMAGE}"
docker pull "${NCCL_NET_IMAGE}"

docker run --rm --privileged \
  --network=host --cap-add=NET_ADMIN \
  --volume /var/lib:/var/lib \
  --env LD_LIBRARY_PATH=/usr/lib64:/var/lib/tcpxo/lib64 \
  "${NCCL_NET_IMAGE}" install --install-nccl

if ! mountpoint -q /var/lib/tcpxo; then
  mount --bind /var/lib/tcpxo /var/lib/tcpxo
  mount -o remount,exec /var/lib/tcpxo
fi

echo "=== 5. Configuring system resource limits ==="
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-unlimited.conf << 'EOF'
* - memlock unlimited
* - nproc unlimited
* - stack unlimited
* - nofile 1048576
* - cpu unlimited
* - rtprio unlimited
EOF

echo "=== 6. Installing aperture mount script and systemd unit ==="
cat > /usr/local/bin/mount_aperture.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Ensure import_helper kernel module is loaded.
modprobe import_helper

# Ensure /var/lib/tcpxo is mounted executable.
if [[ -d /var/lib/tcpxo ]] && ! mountpoint -q /var/lib/tcpxo; then
  mount --bind /var/lib/tcpxo /var/lib/tcpxo
  mount -o remount,exec /var/lib/tcpxo
fi

# Wait for PCIe aperture devices (1ae0:0084) to appear.
MAX_RETRIES=12
retries=0
until lspci -nn -D | grep -q '1ae0:0084' || [[ "${retries}" -ge "${MAX_RETRIES}" ]]; do
  echo "$(date): Waiting for aperture devices (1ae0:0084) (${retries}/${MAX_RETRIES})..."
  sleep 5
  retries=$((retries + 1))
done

if ! lspci -nn -D | grep -q '1ae0:0084'; then
  echo "$(date): ERROR: No aperture devices (1ae0:0084) found."
  exit 1
fi

mkdir -p /dev/aperture_devices
for BDF in $(lspci -nn -D | grep '1ae0:0084' | awk '{print $1}'); do
  mkdir -p "/dev/aperture_devices/${BDF}"
  if ! mountpoint -q "/dev/aperture_devices/${BDF}"; then
    mount --bind "$(readlink -f "/sys/bus/pci/devices/${BDF}")" "/dev/aperture_devices/${BDF}"
  fi
done

# Allow non-root jobs (e.g., LSF/Apptainer) to access aperture resources and dmabuf helper.
chmod a+rX /dev/aperture_devices /dev/aperture_devices/*
chmod 0666 /dev/aperture_devices/*/resource*
if [[ -e /dev/dmabuf_import_helper ]]; then
  chmod 0666 /dev/dmabuf_import_helper
fi
echo "$(date): Mounted $(ls -1 /dev/aperture_devices | wc -l) aperture devices."
EOF
chmod +x /usr/local/bin/mount_aperture.sh

cat > /etc/systemd/system/mount-aperture.service << 'EOF'
[Unit]
Description=Load import_helper and mount GPUDirect-TCPXO aperture devices
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecCondition=/bin/bash -c 'curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/usr/local/bin/mount_aperture.sh

[Install]
WantedBy=multi-user.target
EOF

echo "=== 7. Installing RxDM launcher and systemd unit ==="
cat > /usr/local/bin/start_rxdm.sh << EOF
#!/bin/bash
set -euo pipefail
exec /usr/bin/docker run --rm --name rxdm \\
  --network=host \\
  --cap-add=NET_ADMIN \\
  --gpus all \\
  --privileged \\
  --device /dev/dmabuf_import_helper:/dev/dmabuf_import_helper \\
  --env LD_LIBRARY_PATH=/usr/lib64 \\
  "${RXDM_IMAGE}" \\
  --num_hops=2 --nic_metric_directory=/tmp
EOF
chmod +x /usr/local/bin/start_rxdm.sh

cat > /etc/systemd/system/rxdm.service << 'EOF'
[Unit]
Description=GPUDirect-TCPXO Receive Data Path Manager (RxDM)
After=network-online.target docker.service mount-aperture.service
Wants=network-online.target
Requires=docker.service mount-aperture.service

[Service]
ExecCondition=/bin/bash -c 'curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStartPre=-/usr/bin/docker rm -f rxdm
ExecStart=/usr/local/bin/start_rxdm.sh
ExecStopPost=-/usr/bin/docker stop rxdm
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== 8. Installing optional Local SSD RAID0 service ==="
cat > /usr/local/bin/mount_localssd.sh << 'EOF'
#!/bin/bash
set -euo pipefail

RAID_DEVICE=/dev/md0
DST_MNT=/mnt/localssd
DISK_LABEL=LOCALSSD
OPTIONS=discard,defaults

mkdir -p "${DST_MNT}"
if mountpoint -q "${DST_MNT}"; then
  exit 0
fi

if mount --source LABEL="${DISK_LABEL}" --target="${DST_MNT}" -o "${OPTIONS}" 2>/dev/null; then
  exit 0
fi

# Collect Google Local NVMe SSD devices (exclude persistent disks).
mapfile -t DEVICES < <(lsblk -dn -o NAME,MODEL | awk '/nvme_card/ && !/nvme_card-pd/ {print "/dev/" $1}')
if [[ "${#DEVICES[@]}" -eq 0 ]]; then
  echo "No Local NVMe SSDs detected; skipping RAID0 setup."
  exit 0
fi

if [[ ! -b "${RAID_DEVICE}" ]]; then
  mdadm --create "${RAID_DEVICE}" --run --level=0 --raid-devices="${#DEVICES[@]}" "${DEVICES[@]}"
  mkfs.ext4 -F -E nodiscard "${RAID_DEVICE}"
  tune2fs "${RAID_DEVICE}" -r 131072
  e2label "${RAID_DEVICE}" "${DISK_LABEL}"
fi

mount --source LABEL="${DISK_LABEL}" --target="${DST_MNT}" -o "${OPTIONS}"
chmod 1777 "${DST_MNT}"
EOF
chmod +x /usr/local/bin/mount_localssd.sh

cat > /etc/systemd/system/mount-local-ssd.service << 'EOF'
[Unit]
Description=Assemble Local NVMe SSDs as RAID0 and mount /mnt/localssd
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecCondition=/bin/bash -c 'curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type | grep -q "/a3-megagpu-8g$"'
ExecStart=/usr/local/bin/mount_localssd.sh

[Install]
WantedBy=multi-user.target
EOF

echo "=== 9. Installing NCCL TCPXO environment wrapper (/usr/local/bin/tcpxo_env.sh) ==="
cat > /usr/local/bin/tcpxo_env.sh << 'EOF'
#!/bin/bash
# Wrapper/profile to configure NCCL GPUDirect-TCPXO environment variables on Rocky Linux 8.
# Usage:
#   source /usr/local/bin/tcpxo_env.sh
#   OR: /var/lib/tcpxo/lib64/tcpxo_env.sh <command...>

# Auto-detect primary (default-route) interface and 8 GPU data interfaces.
# Works both on the host and inside minimal containers (without iproute2).
if command -v ip >/dev/null 2>&1; then
  CTRL_NIC="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  CTRL_NIC="${CTRL_NIC:-enp0s12}"
  DATA_NICS="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^enp' | grep -v "^${CTRL_NIC}$" | sort -V | paste -sd ',')"
else
  CTRL_NIC="enp0s12"
  DATA_NICS="$(ls -1 /sys/class/net 2>/dev/null | grep -E '^enp' | grep -v "^${CTRL_NIC}$" | sort -V | paste -sd ',')"
fi

export NCCL_LIB_DIR="${NCCL_LIB_DIR:-/var/lib/tcpxo/lib64}"
if [[ -f "${NCCL_LIB_DIR}/nccl-env-profile.sh" ]]; then
  # shellcheck disable=SC1091
  source "${NCCL_LIB_DIR}/nccl-env-profile.sh"
fi

export NCCL_FASTRAK_CTRL_DEV="${CTRL_NIC}"
export NCCL_SOCKET_IFNAME="${CTRL_NIC}"
if [[ -n "${DATA_NICS}" ]]; then
  export NCCL_FASTRAK_IFNAME="${DATA_NICS}"
fi
export NCCL_FASTRAK_LLCM_DEVICE_DIRECTORY=/dev/aperture_devices
LD_LIBRARY_PATH="${LD_LIBRARY_PATH%:}"
case ":${LD_LIBRARY_PATH:-}:" in
  ":${NCCL_LIB_DIR}:"*) ;;
  *) export LD_LIBRARY_PATH="${NCCL_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
esac
export LD_LIBRARY_PATH

if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi
EOF
chmod +x /usr/local/bin/tcpxo_env.sh
cp /usr/local/bin/tcpxo_env.sh /var/lib/tcpxo/lib64/tcpxo_env.sh

# Save component image references for validation scripts.
cat > /etc/tcpxo-versions.env << EOF
RXDM_IMAGE=${RXDM_IMAGE}
NCCL_NET_IMAGE=${NCCL_NET_IMAGE}
EOF

systemctl daemon-reload
systemctl enable mount-aperture.service rxdm.service mount-local-ssd.service

if [[ "${BUILD_IMAGE_MODE}" == "true" ]]; then
  echo "=== Rocky Linux 8 TCPXO image build complete; shutting down builder VM ==="
  sync
  shutdown -h now
elif echo "${MACHINE_TYPE}" | grep -q "/a3-megagpu-8g$"; then
  echo "=== Starting TCPXO services on A3 Mega VM ==="
  systemctl start mount-aperture.service
  systemctl start rxdm.service
  systemctl start mount-local-ssd.service || true

  echo "Waiting for RxDM initialization..."
  for i in $(seq 1 30); do
    if docker logs rxdm 2>&1 | grep -q "Buffer manager initialization complete"; then
      echo "RxDM initialized successfully."
      break
    fi
    sleep 2
  done
fi

echo "=== Rocky Linux 8 GPUDirect-TCPXO setup completed ==="
