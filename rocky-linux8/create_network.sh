#!/bin/bash
# Creates 1 management VPC and 8 GPUDirect-TCPXO data VPCs (MTU 8244),
# with subnets and firewall rules matching the Google Cloud A3 Mega guide.
set -euo pipefail

: "${PROJECT:?Set PROJECT in set_envs.sh and source it}"
: "${REGION:?Set REGION in set_envs.sh and source it}"
: "${NETWORK_PREFIX:?Set NETWORK_PREFIX in set_envs.sh and source it}"
SSH_SOURCE_IP_RANGE="${SSH_SOURCE_IP_RANGE:-35.235.240.0/20}"

ensure_network() {
  local name="$1"
  if gcloud compute networks describe "${name}" --project="${PROJECT}" >/dev/null 2>&1; then
    echo "Network ${name} already exists, skipping."
  else
    gcloud compute networks create "${name}" \
      --project="${PROJECT}" \
      --subnet-mode=custom \
      --mtu=8244
  fi
}

ensure_subnet() {
  local name="$1" network="$2" range="$3"
  if gcloud compute networks subnets describe "${name}" --project="${PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
    echo "Subnet ${name} already exists, skipping."
  else
    gcloud compute networks subnets create "${name}" \
      --project="${PROJECT}" \
      --network="${network}" \
      --region="${REGION}" \
      --range="${range}"
  fi
}

ensure_firewall() {
  local name="$1" network="$2" rules="$3" source_ranges="$4"
  if gcloud compute firewall-rules describe "${name}" --project="${PROJECT}" >/dev/null 2>&1; then
    echo "Firewall rule ${name} already exists, skipping."
  else
    gcloud compute firewall-rules create "${name}" \
      --project="${PROJECT}" \
      --network="${network}" \
      --action=ALLOW \
      --rules="${rules}" \
      --source-ranges="${source_ranges}"
  fi
}

echo "=== Creating management VPC (${NETWORK_PREFIX}-mgmt-net) ==="
ensure_network "${NETWORK_PREFIX}-mgmt-net"
ensure_subnet "${NETWORK_PREFIX}-mgmt-sub" "${NETWORK_PREFIX}-mgmt-net" "192.168.0.0/24"

# Allow all internal TCP/UDP/ICMP between nodes on management VPC
# (required for NCCL test SSH on port 222 and dynamic MPI ports on enp0s12).
ensure_firewall "${NETWORK_PREFIX}-mgmt-internal" "${NETWORK_PREFIX}-mgmt-net" \
  "tcp:0-65535,udp:0-65535,icmp" "192.168.0.0/16"

ensure_firewall "${NETWORK_PREFIX}-mgmt-external-ssh" "${NETWORK_PREFIX}-mgmt-net" \
  "tcp:22" "${SSH_SOURCE_IP_RANGE}"

ensure_firewall "${NETWORK_PREFIX}-mgmt-external-ping" "${NETWORK_PREFIX}-mgmt-net" \
  "icmp" "${SSH_SOURCE_IP_RANGE}"

echo "=== Creating 8 GPUDirect-TCPXO data VPCs (${NETWORK_PREFIX}-data-net-1..8) in parallel ==="
pids=()
for N in $(seq 1 8); do
  (
    ensure_network "${NETWORK_PREFIX}-data-net-${N}"
    ensure_subnet "${NETWORK_PREFIX}-data-sub-${N}" "${NETWORK_PREFIX}-data-net-${N}" "192.168.${N}.0/24"
    ensure_firewall "${NETWORK_PREFIX}-data-internal-${N}" "${NETWORK_PREFIX}-data-net-${N}" \
      "tcp:0-65535,udp:0-65535,icmp" "192.168.0.0/16"
  ) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "${pid}"
done

echo "All 9 A3 Mega VPC networks, subnets, and firewall rules are ready."
