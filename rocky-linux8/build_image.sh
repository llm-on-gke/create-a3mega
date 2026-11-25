#!/bin/bash
# Builds a custom Rocky Linux 8 GPUDirect-TCPXO GCE image from
# rocky-linux-8-optimized-gcp-nvidia-580 (rocky-linux-accelerator-cloud).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${PROJECT:?Set PROJECT in set_envs.sh and source it}"
: "${ZONE:?Set ZONE in set_envs.sh and source it}"
: "${NETWORK_PREFIX:?Set NETWORK_PREFIX in set_envs.sh and source it}"

IMAGE_PROJECT="${IMAGE_PROJECT:-$PROJECT}"
BASE_IMAGE_PROJECT="${BASE_IMAGE_PROJECT:-rocky-linux-accelerator-cloud}"
BASE_IMAGE_FAMILY="${BASE_IMAGE_FAMILY:-rocky-linux-8-optimized-gcp-nvidia-580}"
CUSTOM_IMAGE_FAMILY="${CUSTOM_IMAGE_FAMILY:-rocky-8-a3mega-tcpxo}"
BUILDER_MACHINE_TYPE="${BUILDER_MACHINE_TYPE:-n2-standard-8}"
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-200}"
BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-ssd}"
ENABLE_OSLOGIN="${ENABLE_OSLOGIN:-true}"
RXDM_IMAGE="${RXDM_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.21}"
NCCL_NET_IMAGE="${NCCL_NET_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.15}"
NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.17.8-1}"

SYS_NET="${NETWORK_PREFIX}-mgmt-net"
SYS_SUBNET="${NETWORK_PREFIX}-mgmt-sub"
TIMESTAMP="$(date -u +%Y%m%d%H%M%Sz)"
VM_NAME="${CUSTOM_IMAGE_FAMILY}-${TIMESTAMP}"

METADATA="build-image=true,rxdm-image=${RXDM_IMAGE},nccl-net-image=${NCCL_NET_IMAGE},nvidia-container-toolkit-version=${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
if [[ "${ENABLE_OSLOGIN}" == "true" ]]; then
  METADATA="${METADATA},enable-oslogin=true"
fi

CREATE_ARGS=(
  "${VM_NAME}"
  --project="${PROJECT}"
  --zone="${ZONE}"
  --machine-type="${BUILDER_MACHINE_TYPE}"
  --image-project="${BASE_IMAGE_PROJECT}"
  --image-family="${BASE_IMAGE_FAMILY}"
  --no-boot-disk-auto-delete
  --boot-disk-size="${BOOT_DISK_SIZE}"
  --boot-disk-type="${BOOT_DISK_TYPE}"
  --network-interface="nic-type=GVNIC,network=${SYS_NET},subnet=${SYS_SUBNET}"
  --scopes=https://www.googleapis.com/auth/cloud-platform
  --metadata="${METADATA}"
  --metadata-from-file="startup-script=${SCRIPT_DIR}/startup_script_rocky.sh"
  --labels=goog-ec-src=vm_add-gcloud,purpose=a3mega-rocky-image-build
)

if [[ -n "${SERVICE_ACCOUNT:-}" ]]; then
  CREATE_ARGS+=(--service-account="${SERVICE_ACCOUNT}")
fi

echo "=== Launching builder VM ${VM_NAME} from ${BASE_IMAGE_PROJECT}/${BASE_IMAGE_FAMILY} ==="
gcloud compute instances create "${CREATE_ARGS[@]}"

start_ts=$(date +%s)
timeout_sec=2400

echo "=== Waiting for builder VM ${VM_NAME} to complete startup script and shut down ==="
echo "Tip: Inspect live logs with:"
echo "  gcloud compute instances get-serial-port-output ${VM_NAME} --project=${PROJECT} --zone=${ZONE}"
while true; do
  status="$(gcloud compute instances describe "${VM_NAME}" \
    --project="${PROJECT}" \
    --zone="${ZONE}" \
    --format="value(status)")"
  if [[ "${status}" == "TERMINATED" ]]; then
    echo "Builder VM ${VM_NAME} reached TERMINATED."
    break
  fi
  # Fail fast if the startup script exited with a non-zero status while VM is still running.
  if [[ "${status}" == "RUNNING" ]]; then
    serial_tail="$(gcloud compute instances get-serial-port-output "${VM_NAME}" \
      --project="${PROJECT}" --zone="${ZONE}" 2>/dev/null | tail -n 30 || true)"
    if echo "${serial_tail}" | grep -qE 'startup-script.*exit status [1-9]'; then
      echo "ERROR: startup_script_rocky.sh failed on builder VM ${VM_NAME}:"
      echo "${serial_tail}"
      echo "Inspect or clean up builder VM manually: gcloud compute instances delete ${VM_NAME} --project=${PROJECT} --zone=${ZONE} --delete-disks=all"
      exit 1
    fi
  fi
  now_ts=$(date +%s)
  elapsed=$((now_ts - start_ts))
  if [[ "${elapsed}" -gt "${timeout_sec}" ]]; then
    echo "ERROR: Builder VM ${VM_NAME} did not terminate within ${timeout_sec}s (status: ${status})."
    echo "Check serial logs before deleting:"
    echo "  gcloud compute instances get-serial-port-output ${VM_NAME} --project=${PROJECT} --zone=${ZONE}"
    exit 1
  fi
  echo "Waiting (${elapsed}s elapsed, status=${status})..."
  sleep 20
done

echo "=== Creating custom image ${VM_NAME} in project ${IMAGE_PROJECT} (family: ${CUSTOM_IMAGE_FAMILY}) ==="
gcloud -q compute images create "${VM_NAME}" \
  --project="${IMAGE_PROJECT}" \
  --source-disk="projects/${PROJECT}/zones/${ZONE}/disks/${VM_NAME}" \
  --family="${CUSTOM_IMAGE_FAMILY}" \
  --description="Rocky Linux 8 A3 Mega GPUDirect-TCPXO (base=${BASE_IMAGE_FAMILY}, rxdm=${RXDM_IMAGE}, nccl=${NCCL_NET_IMAGE})"

echo "=== Cleaning up temporary builder VM and boot disk ==="
gcloud -q compute instances delete "${VM_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --delete-disks=all

echo "=== Custom image ready ==="
echo "  Image:   ${VM_NAME}"
echo "  Family:  ${CUSTOM_IMAGE_FAMILY}"
echo "  Project: ${IMAGE_PROJECT}"
