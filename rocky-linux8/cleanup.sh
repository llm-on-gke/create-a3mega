#!/bin/bash
# Tears down A3 Mega Rocky Linux 8 test resources created by these scripts.
#
# Usage:
#   source set_envs.sh
#   bash cleanup.sh --vms        # Delete VMs matching ${VM_NAME_PREFIX}-* (and Flex MIG/template)
#   bash cleanup.sh --networks   # Delete the 9 VPC networks, subnets, and firewall rules
#   bash cleanup.sh --all        # Delete VMs, MIG/template, and networks
set -euo pipefail

: "${PROJECT:?Set PROJECT in set_envs.sh and source it}"
: "${REGION:?Set REGION in set_envs.sh and source it}"
: "${ZONE:?Set ZONE in set_envs.sh and source it}"
: "${NETWORK_PREFIX:?Set NETWORK_PREFIX in set_envs.sh and source it}"
VM_NAME_PREFIX="${VM_NAME_PREFIX:-a3mega-rocky}"

delete_vms() {
  echo "=== Deleting VMs matching ${VM_NAME_PREFIX}-* in ${ZONE} ==="
  mapfile -t vms < <(gcloud compute instances list \
    --project="${PROJECT}" \
    --zones="${ZONE}" \
    --filter="name~^${VM_NAME_PREFIX}-" \
    --format="value(name)")
  if [[ "${#vms[@]}" -gt 0 ]]; then
    gcloud -q compute instances delete "${vms[@]}" --project="${PROJECT}" --zone="${ZONE}"
  else
    echo "No matching VMs found."
  fi

  # Also clean up optional DWS Flex MIG and template if present.
  if gcloud compute instance-groups managed describe "${VM_NAME_PREFIX}-flex-mig" \
      --project="${PROJECT}" --zone="${ZONE}" >/dev/null 2>&1; then
    gcloud -q compute instance-groups managed delete "${VM_NAME_PREFIX}-flex-mig" \
      --project="${PROJECT}" --zone="${ZONE}"
  fi
  if gcloud compute instance-templates describe "${VM_NAME_PREFIX}-flex-tmpl" \
      --project="${PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
    gcloud -q compute instance-templates delete "${VM_NAME_PREFIX}-flex-tmpl" \
      --project="${PROJECT}" --region="${REGION}"
  fi
}

delete_networks() {
  echo "=== Deleting firewall rules, subnets, and VPCs for prefix ${NETWORK_PREFIX} ==="
  mapfile -t existing_fw < <(gcloud compute firewall-rules list \
    --project="${PROJECT}" \
    --format="value(name,network.basename())" \
    | awk -v p="${NETWORK_PREFIX}" '$2 ~ "^" p "-(mgmt-net|data-net-[1-8])$" {print $1}')
  if [[ "${#existing_fw[@]}" -gt 0 ]]; then
    gcloud -q compute firewall-rules delete "${existing_fw[@]}" --project="${PROJECT}"
  fi

  local subnets=("${NETWORK_PREFIX}-mgmt-sub")
  for N in $(seq 1 8); do
    subnets+=("${NETWORK_PREFIX}-data-sub-${N}")
  done
  local existing_subs=()
  for sub in "${subnets[@]}"; do
    if gcloud compute networks subnets describe "${sub}" --project="${PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
      existing_subs+=("${sub}")
    fi
  done
  if [[ "${#existing_subs[@]}" -gt 0 ]]; then
    gcloud -q compute networks subnets delete "${existing_subs[@]}" --project="${PROJECT}" --region="${REGION}"
  fi

  local nets=("${NETWORK_PREFIX}-mgmt-net")
  for N in $(seq 1 8); do
    nets+=("${NETWORK_PREFIX}-data-net-${N}")
  done
  local existing_nets=()
  for net in "${nets[@]}"; do
    if gcloud compute networks describe "${net}" --project="${PROJECT}" >/dev/null 2>&1; then
      existing_nets+=("${net}")
    fi
  done
  if [[ "${#existing_nets[@]}" -gt 0 ]]; then
    gcloud -q compute networks delete "${existing_nets[@]}" --project="${PROJECT}"
  fi
}

case "${1:-}" in
  --vms)
    delete_vms
    ;;
  --networks)
    delete_networks
    ;;
  --all)
    delete_vms
    delete_networks
    ;;
  *)
    echo "Usage: $0 [--vms | --networks | --all]"
    exit 1
    ;;
esac

echo "=== Cleanup complete ==="
