#!/bin/bash
# Validation helper for Rocky Linux 8 A3 Mega GPUDirect-TCPXO VMs.
#
# Usage (run on an A3 Mega VM):
#   bash validate_tcpxo.sh                    # Run host & RxDM health checks
#   bash validate_tcpxo.sh --start-nccl       # Start the official NCCL test container
#   bash validate_tcpxo.sh --test VM1 VM2     # Run 2-node all_gather_perf benchmark
#                                             # (requires --start-nccl on both VM1 and VM2)
set -euo pipefail

if [[ -f /etc/tcpxo-versions.env ]]; then
  # shellcheck disable=SC1091
  source /etc/tcpxo-versions.env
fi
NCCL_NET_IMAGE="${NCCL_NET_IMAGE:-us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/nccl-plugin-gpudirecttcpx-dev:v1.0.15}"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

detect_nics() {
  CTRL_NIC="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  CTRL_NIC="${CTRL_NIC:-enp0s12}"
  DATA_NICS="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^enp' | grep -v "^${CTRL_NIC}$" | sort -V | paste -sd ',')"
}

run_host_checks() {
  local failed=0
  echo "=========================================="
  echo " A3 Mega Rocky Linux 8 TCPXO Node Check"
  echo " Host: $(hostname)"
  echo "=========================================="

  echo "[1/7] OS & Kernel:"
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
  uname -r

  echo "[2/7] NVIDIA Driver & GPUs:"
  if nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader; then
    local gpu_count
    gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
    echo "  -> Detected ${gpu_count} GPUs"
    [[ "${gpu_count}" -eq 8 ]] || { echo "  FAIL: Expected 8 GPUs"; failed=1; }
  else
    echo "  FAIL: nvidia-smi failed"
    failed=1
  fi

  echo "[3/7] Network Interfaces & MTU 8244:"
  detect_nics
  ip -br link | grep -E '^(enp|eth)' || true
  local nic_count
  nic_count="$(echo "${DATA_NICS}" | tr ',' '\n' | grep -c . || true)"
  echo "  -> Control NIC: ${CTRL_NIC}"
  echo "  -> Data NICs (${nic_count}): ${DATA_NICS}"
  [[ "${nic_count}" -eq 8 ]] || { echo "  FAIL: Expected 8 data NICs"; failed=1; }
  local bad_mtu=0
  for nic in $(echo "${DATA_NICS}" | tr ',' ' '); do
    local mtu
    mtu="$(ip -o link show "${nic}" | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
    if [[ "${mtu}" != "8244" ]]; then
      echo "  WARN: ${nic} has MTU=${mtu} (expected 8244)"
      bad_mtu=1
    fi
  done
  [[ "${bad_mtu}" -eq 0 ]] && echo "  -> All 8 data NICs have MTU 8244"

  echo "[4/7] Aperture Devices (PCIe 1ae0:0084):"
  local pci_apertures mounted_apertures
  pci_apertures="$(lspci -nn -D | grep -c '1ae0:0084' || true)"
  mounted_apertures="$(find /dev/aperture_devices -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)"
  echo "  -> PCIe devices: ${pci_apertures}, Mounted in /dev/aperture_devices: ${mounted_apertures}"
  [[ "${pci_apertures}" -eq 8 && "${mounted_apertures}" -eq 8 ]] || { echo "  FAIL: Expected 8 aperture devices"; failed=1; }

  echo "[5/7] dmabuf import_helper kernel module:"
  if lsmod | grep -q '^import_helper\b' && [[ -c /dev/dmabuf_import_helper ]]; then
    lsmod | grep '^import_helper\b'
    ls -l /dev/dmabuf_import_helper
  else
    echo "  FAIL: import_helper module or /dev/dmabuf_import_helper missing"
    failed=1
  fi

  echo "[6/7] RxDM container status:"
  if ${DOCKER} ps --filter "name=^/rxdm$" --format "{{.Names}} {{.Status}}" | grep -q '^rxdm '; then
    ${DOCKER} ps --filter "name=^/rxdm$" --format "  -> {{.Names}}: {{.Status}} ({{.Image}})"
    if ${DOCKER} logs rxdm 2>&1 | grep -q "Buffer manager initialization complete"; then
      echo "  -> RxDM log confirmed: Buffer manager initialization complete"
    else
      echo "  FAIL: RxDM running but 'Buffer manager initialization complete' not yet logged"
      failed=1
    fi
  else
    echo "  FAIL: rxdm container is not running"
    failed=1
  fi

  echo "[7/7] NCCL TCPXO Plugin Libraries (/var/lib/tcpxo/lib64):"
  if [[ -f /var/lib/tcpxo/lib64/libnccl-net.so && -f /var/lib/tcpxo/lib64/libnccl.so ]]; then
    ls -1 /var/lib/tcpxo/lib64
  else
    echo "  FAIL: Missing libnccl-net.so or libnccl.so in /var/lib/tcpxo/lib64"
    failed=1
  fi

  echo "=========================================="
  if [[ "${failed}" -eq 0 ]]; then
    echo " RESULT: ALL HOST CHECKS PASSED"
  else
    echo " RESULT: ONE OR MORE CHECKS FAILED"
    exit 1
  fi
}

start_nccl_container() {
  echo "=== Starting official NCCL test container (${NCCL_NET_IMAGE}) ==="
  local -a aperture_args=()
  while IFS= read -r line; do
    local bdf host_dev container_dev
    bdf="$(echo "${line}" | awk '{print $1}')"
    host_dev="/sys/bus/pci/devices/${bdf}"
    container_dev="/dev/aperture_devices/${bdf}"
    aperture_args+=(--mount "type=bind,src=${host_dev},target=${container_dev}")
  done < <(lspci -nn -D | grep '1ae0:0084')

  ${DOCKER} rm -f nccl >/dev/null 2>&1 || true
  ${DOCKER} run --rm --detach --name nccl \
    --network=host --cap-add=NET_ADMIN \
    --privileged \
    --volume /var/lib/:/var/lib \
    --shm-size=8g \
    --gpus all \
    "${aperture_args[@]}" \
    --device /dev/dmabuf_import_helper:/dev/dmabuf_import_helper \
    --env LD_LIBRARY_PATH=/usr/lib64:/var/lib/tcpxo/lib64 \
    "${NCCL_NET_IMAGE}" daemon

  ${DOCKER} ps --filter "name=^/nccl$"
}

run_two_node_test() {
  local vm1="$1" vm2="$2"
  detect_nics
  echo "=== Running 2-node GPUDirect-TCPXO all_gather_perf (${vm1}, ${vm2}) ==="
  echo "  Control NIC: ${CTRL_NIC}"
  echo "  Data NICs:   ${DATA_NICS}"
  ${DOCKER} exec nccl bash -c "
    set -euo pipefail
    /scripts/init_ssh.sh ${vm1} ${vm2}
    /scripts/gen_hostfiles.sh ${vm1} ${vm2}
    /scripts/run-nccl-tcpxo.sh all_gather_perf \"\${LD_LIBRARY_PATH}\" 8 \
      \"${DATA_NICS}\" 1M 8G 3 2 10 8 2 10 \"${CTRL_NIC}\"
  "
}

case "${1:-}" in
  "")
    run_host_checks
    ;;
  --start-nccl)
    run_host_checks
    start_nccl_container
    ;;
  --test)
    if [[ "$#" -ne 3 ]]; then
      echo "Usage: $0 --test <VM_NAME_1> <VM_NAME_2>"
      exit 1
    fi
    run_two_node_test "$2" "$3"
    ;;
  *)
    echo "Usage:"
    echo "  $0                    # Verify host, NICs, apertures, import_helper, RxDM, and NCCL plugin"
    echo "  $0 --start-nccl       # Run host checks and start the 'nccl' benchmark container"
    echo "  $0 --test VM1 VM2     # Run 2-node all_gather_perf benchmark via 'nccl' container"
    exit 1
    ;;
esac
