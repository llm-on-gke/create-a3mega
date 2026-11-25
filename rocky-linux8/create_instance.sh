#!/bin/bash
# Creates A3 Mega (a3-megagpu-8g) Rocky Linux 8 GPUDirect-TCPXO VM(s).
#
# Supports all provisioning models from the public GPUDirect guide:
#   PROVISION_MODE=SPOT | STANDARD | FLEX_START | RESERVATION_BOUND
#
# Supports both:
#   USE_CUSTOM_IMAGE=true  -> Boots from custom image built by build_image.sh
#   USE_CUSTOM_IMAGE=false -> Boots directly from rocky-linux-8-optimized-gcp-nvidia-580
#                             with startup_script_rocky.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${PROJECT:?Set PROJECT in set_envs.sh and source it}"
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
PROVISION_MODE="$(echo "${PROVISION_MODE:-SPOT}" | tr '[:lower:]' '[:upper:]')"
TERMINATION_ACTION="$(echo "${TERMINATION_ACTION:-DELETE}" | tr '[:lower:]' '[:upper:]')"
MAX_RUN_DURATION="${MAX_RUN_DURATION:-24h}"
VALID_FOR_DURATION="${VALID_FOR_DURATION:-0s}"
RESERVATION="${RESERVATION:-}"
PLACEMENT_POLICY="${PLACEMENT_POLICY:-}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-}"
ENABLE_OSLOGIN="${ENABLE_OSLOGIN:-true}"
RXDM_IMAGE="${RXDM_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.21}"
NCCL_NET_IMAGE="${NCCL_NET_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.15}"
NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.17.8-1}"

COMMON_ARGS=(
  --project="${PROJECT}"
  --zone="${ZONE}"
  --machine-type=a3-megagpu-8g
  --on-host-maintenance=TERMINATE
  --restart-on-failure
  --boot-disk-size="${BOOT_DISK_SIZE}"
  --boot-disk-type="${BOOT_DISK_TYPE}"
  --scopes=https://www.googleapis.com/auth/cloud-platform
  --labels=goog-ec-src=vm_add-gcloud,os=rocky-linux-8,gpudirect=tcpxo
  --network-interface="nic-type=GVNIC,network=${NETWORK_PREFIX}-mgmt-net,subnet=${NETWORK_PREFIX}-mgmt-sub"
)

# Attach the 8 GPUDirect-TCPXO data NICs without external IPs.
for N in $(seq 1 8); do
  COMMON_ARGS+=(
    --network-interface="nic-type=GVNIC,network=${NETWORK_PREFIX}-data-net-${N},subnet=${NETWORK_PREFIX}-data-sub-${N},no-address"
  )
done

# Select image source (pre-baked custom image vs. direct base image + startup script).
METADATA_ITEMS=()
if [[ "${ENABLE_OSLOGIN}" == "true" ]]; then
  METADATA_ITEMS+=("enable-oslogin=true")
fi

if [[ "${USE_CUSTOM_IMAGE}" == "true" ]]; then
  COMMON_ARGS+=(
    --image-project="${IMAGE_PROJECT}"
    --image-family="${CUSTOM_IMAGE_FAMILY}"
  )
else
  COMMON_ARGS+=(
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
  IFS=','; COMMON_ARGS+=(--metadata="${METADATA_ITEMS[*]}"); unset IFS
fi

if [[ -n "${SERVICE_ACCOUNT}" ]]; then
  COMMON_ARGS+=(--service-account="${SERVICE_ACCOUNT}")
fi

if [[ -n "${PLACEMENT_POLICY}" ]]; then
  COMMON_ARGS+=(--resource-policies="${PLACEMENT_POLICY}")
fi

# Provisioning model flags matching https://docs.cloud.google.com/compute/docs/gpus/gpudirect#rocky
case "${PROVISION_MODE}" in
  STANDARD)
    COMMON_ARGS+=(--provisioning-model=STANDARD)
    if [[ -n "${RESERVATION}" ]]; then
      COMMON_ARGS+=(
        --reservation-affinity=specific
        --reservation="${RESERVATION}"
      )
    fi
    ;;
  SPOT)
    COMMON_ARGS+=(
      --provisioning-model=SPOT
      --instance-termination-action="${TERMINATION_ACTION}"
    )
    ;;
  RESERVATION_BOUND)
    : "${RESERVATION:?RESERVATION must be set when PROVISION_MODE=RESERVATION_BOUND}"
    COMMON_ARGS+=(
      --provisioning-model=RESERVATION_BOUND
      --instance-termination-action="${TERMINATION_ACTION}"
      --reservation-affinity=specific
      --reservation="${RESERVATION}"
    )
    ;;
  FLEX_START)
    COMMON_ARGS+=(
      --provisioning-model=FLEX_START
      --instance-termination-action="${TERMINATION_ACTION}"
      --max-run-duration="${MAX_RUN_DURATION}"
      --request-valid-for-duration="${VALID_FOR_DURATION}"
    )
    if [[ "${TERMINATION_ACTION}" == "STOP" ]]; then
      COMMON_ARGS+=(--discard-local-ssds-at-termination-timestamp=true)
    fi
    ;;
  *)
    echo "ERROR: Unsupported PROVISION_MODE='${PROVISION_MODE}'. Use STANDARD, SPOT, FLEX_START, or RESERVATION_BOUND."
    exit 1
    ;;
esac

echo "=== Creating ${COUNT} A3 Mega Rocky Linux 8 VM(s) (mode=${PROVISION_MODE}, custom_image=${USE_CUSTOM_IMAGE}) ==="
if [[ "${PROVISION_MODE}" == "FLEX_START" ]]; then
  if [[ "${COUNT}" -gt 1 ]]; then
    echo "NOTE: Direct FLEX_START creates VMs independently. For gang-scheduled all-or-nothing"
    echo "      multi-node DWS Flex-start, use create_dws_flex.sh instead."
  fi
  for i in $(seq -w 1 "${COUNT}"); do
    VM_NAME="${VM_NAME_PREFIX}-$(printf '%04d' "$((10#$i))")"
    gcloud compute instances create "${VM_NAME}" "${COMMON_ARGS[@]}"
  done
else
  gcloud compute instances bulk create \
    --count="${COUNT}" \
    --name-pattern="${VM_NAME_PREFIX}-####" \
    "${COMMON_ARGS[@]}"
fi
