#!/bin/bash
# Configuration for creating Rocky Linux 8 A3 Mega (a3-megagpu-8g) VMs with GPUDirect-TCPXO.
# Edit the required variables below, then run:
#   source set_envs.sh

# --- Required GCP Settings ---
export PROJECT="${PROJECT:-<PROJECT_ID>}"
export IMAGE_PROJECT="${IMAGE_PROJECT:-$PROJECT}"
export REGION="${REGION:-us-west1}"
export ZONE="${ZONE:-us-west1-a}"
export NETWORK_PREFIX="${NETWORK_PREFIX:-a3mega-rocky}"

# Source CIDR allowed to SSH over TCP/22 on the management VPC.
# Defaults to Google IAP range (35.235.240.0/20).
export SSH_SOURCE_IP_RANGE="${SSH_SOURCE_IP_RANGE:-35.235.240.0/20}"

# --- Base & Custom Image Settings ---
# Published GPUDirect-TCPXO Rocky Linux 8 image (includes NVIDIA 580 driver).
# Note: Use project 'rocky-linux-accelerator-cloud' (NOT 'rocky-linux-cloud').
export BASE_IMAGE_PROJECT="${BASE_IMAGE_PROJECT:-rocky-linux-accelerator-cloud}"
export BASE_IMAGE_FAMILY="${BASE_IMAGE_FAMILY:-rocky-linux-8-optimized-gcp-nvidia-580}"

# Custom image family built by build_image.sh (stored in $IMAGE_PROJECT).
export CUSTOM_IMAGE_FAMILY="${CUSTOM_IMAGE_FAMILY:-rocky-8-a3mega-tcpxo}"
# Set to "true" to launch VMs from the custom image built by build_image.sh.
# Set to "false" to launch directly from BASE_IMAGE_FAMILY using startup_script_rocky.sh.
export USE_CUSTOM_IMAGE="${USE_CUSTOM_IMAGE:-true}"
export BUILDER_MACHINE_TYPE="${BUILDER_MACHINE_TYPE:-n2-standard-8}"

# --- VM & Provisioning Settings ---
export VM_NAME_PREFIX="${VM_NAME_PREFIX:-a3mega-rocky}"
export COUNT="${COUNT:-2}"
export BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-200}"
export BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-ssd}"

# Provisioning model: SPOT | STANDARD | FLEX_START | RESERVATION_BOUND
export PROVISION_MODE="${PROVISION_MODE:-SPOT}"
# Termination action for SPOT, FLEX_START, and RESERVATION_BOUND: DELETE | STOP
export TERMINATION_ACTION="${TERMINATION_ACTION:-DELETE}"

# FLEX_START / DWS Flex settings
export MAX_RUN_DURATION="${MAX_RUN_DURATION:-24h}"
export VALID_FOR_DURATION="${VALID_FOR_DURATION:-0s}"

# Optional: Reservation name or URL for STANDARD (CUD) or RESERVATION_BOUND (DWS Calendar).
# Example: projects/$PROJECT/reservations/a3-mega-reservation
export RESERVATION="${RESERVATION:-}"

# Optional: Compact placement policy name (same region as ZONE).
export PLACEMENT_POLICY="${PLACEMENT_POLICY:-}"

# Optional: Custom service account email (leave empty to use Compute Engine default SA).
export SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-}"

# Optional: Enable OS Login metadata on VMs.
export ENABLE_OSLOGIN="${ENABLE_OSLOGIN:-true}"

# --- GPUDirect-TCPXO Component Versions (matched to NVIDIA 580 driver) ---
export RXDM_IMAGE="${RXDM_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.21}"
export NCCL_NET_IMAGE="${NCCL_NET_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.15}"
export NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.17.8-1}"
