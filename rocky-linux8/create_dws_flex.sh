#!/bin/bash
# Creates gang-scheduled (all-or-nothing) A3 Mega Rocky Linux 8 VMs via
# Managed Instance Group (MIG) + DWS Flex-Start resize-request.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${PROJECT:?Set PROJECT in set_envs.sh and source it}"
: "${REGION:?Set REGION in set_envs.sh and source it}"
: "${ZONE:?Set ZONE in set_envs.sh and source it}"
: "${NETWORK_PREFIX:?Set NETWORK_PREFIX in set_envs.sh and source it}"

IMAGE_PROJECT="${IMAGE_PROJECT:-$PROJECT}"
BASE_IMAGE_PROJECT="${BASE_IMAGE_PROJECT:-rocky-linux-accelerator-cloud}"
BASE_IMAGE_FAMILY="${BASE_IMAGE_FAMILY:-rocky-linux-8-optimized-gcp-nvidia-580}"
CUSTOM_IMAGE_FAMILY="${CUSTOM_IMAGE_FAMILY:-rocky-8-a3mega-tcpxo}"
USE_CUSTOM_IMAGE="${USE_CUSTOM_IMAGE:-true}"

VM_NAME_PREFIX="${VM_NAME_PREFIX:-a3mega-rocky}"
COUNT="${COUNT:-2}"
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-200}"
BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-ssd}"
MAX_RUN_DURATION="${MAX_RUN_DURATION:-24h}"
TERMINATION_ACTION="$(echo "${TERMINATION_ACTION:-DELETE}" | tr '[:lower:]' '[:upper:]')"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-}"
ENABLE_OSLOGIN="${ENABLE_OSLOGIN:-true}"
RXDM_IMAGE="${RXDM_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.21}"
NCCL_NET_IMAGE="${NCCL_NET_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.15}"
NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.17.8-1}"

TEMPLATE_NAME="${VM_NAME_PREFIX}-flex-tmpl"
MIG_NAME="${VM_NAME_PREFIX}-flex-mig"
REQ_NAME="${VM_NAME_PREFIX}-flex-req-$(date -u +%Y%m%d%H%M)"

TEMPLATE_ARGS=(
  "${TEMPLATE_NAME}"
  --project="${PROJECT}"
  --instance-template-region="${REGION}"
  --machine-type=a3-megagpu-8g
  --on-host-maintenance=TERMINATE
  --no-restart-on-failure
  --provisioning-model=FLEX_START
  --instance-termination-action="${TERMINATION_ACTION}"
  --max-run-duration="${MAX_RUN_DURATION}"
  --reservation-affinity=none
  --boot-disk-size="${BOOT_DISK_SIZE}"
  --boot-disk-type="${BOOT_DISK_TYPE}"
  --scopes=https://www.googleapis.com/auth/cloud-platform
  --labels=goog-ec-src=vm_add-gcloud,os=rocky-linux-8,gpudirect=tcpxo
  --network-interface="nic-type=GVNIC,network=${NETWORK_PREFIX}-mgmt-net,subnet=${NETWORK_PREFIX}-mgmt-sub"
)

if [[ "${TERMINATION_ACTION}" == "STOP" ]]; then
  TEMPLATE_ARGS+=(--discard-local-ssds-at-termination-timestamp=true)
fi

for N in $(seq 1 8); do
  TEMPLATE_ARGS+=(
    --network-interface="nic-type=GVNIC,network=${NETWORK_PREFIX}-data-net-${N},subnet=${NETWORK_PREFIX}-data-sub-${N},no-address"
  )
done

METADATA_ITEMS=()
if [[ "${ENABLE_OSLOGIN}" == "true" ]]; then
  METADATA_ITEMS+=("enable-oslogin=true")
fi

if [[ "${USE_CUSTOM_IMAGE}" == "true" ]]; then
  TEMPLATE_ARGS+=(
    --image-project="${IMAGE_PROJECT}"
    --image-family="${CUSTOM_IMAGE_FAMILY}"
  )
else
  TEMPLATE_ARGS+=(
    --image-project="${BASE_IMAGE_PROJECT}"
    --image-family="${BASE_IMAGE_FAMILY}"
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup_script_rocky.sh"
  )
  METADATA_ITEMS+=(
    "rxdm-image=${RXDM_IMAGE}"
    "nccl-net-image=${NCCL_NET_IMAGE}"
    "nvidia-container-toolkit-version=${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
  )
fi

if [[ "${#METADATA_ITEMS[@]}" -gt 0 ]]; then
  IFS=','; TEMPLATE_ARGS+=(--metadata="${METADATA_ITEMS[*]}"); unset IFS
fi

if [[ -n "${SERVICE_ACCOUNT}" ]]; then
  TEMPLATE_ARGS+=(--service-account="${SERVICE_ACCOUNT}")
fi

echo "=== Creating regional instance template ${TEMPLATE_NAME} ==="
gcloud compute instance-templates create "${TEMPLATE_ARGS[@]}"

echo "=== Creating Managed Instance Group ${MIG_NAME} (initial size 0) ==="
gcloud compute instance-groups managed create "${MIG_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --size=0 \
  --default-action-on-vm-failure=do-nothing \
  --template="projects/${PROJECT}/regions/${REGION}/instanceTemplates/${TEMPLATE_NAME}"

echo "=== Submitting DWS Flex-Start resize request ${REQ_NAME} for ${COUNT} VMs (${MAX_RUN_DURATION}) ==="
gcloud compute instance-groups managed resize-requests create "${MIG_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --resize-request="${REQ_NAME}" \
  --resize-by="${COUNT}" \
  --requested-run-duration="${MAX_RUN_DURATION}"

echo "Monitor status with:"
echo "  gcloud compute instance-groups managed resize-requests describe ${REQ_NAME} --instance-group=${MIG_NAME} --zone=${ZONE} --project=${PROJECT}"
