# create-a3mega (Rocky Linux 8 GPUDirect-TCPXO)

Simplified scripts to provision, configure, and validate **A3 Mega (`a3-megagpu-8g`, 8x NVIDIA H100)** VMs with **GPUDirect-TCPXO** on **Rocky Linux 8**, based on the official Google Cloud guide:
[Create an A3 Mega, A3 High, or A3 Edge instance with GPUDirect enabled (Rocky Linux)](https://docs.cloud.google.com/compute/docs/gpus/gpudirect#rocky).

> **Note:** For fully managed clusters, Google Cloud also offers [Cluster Toolkit (Slurm)](https://cloud.google.com/cluster-toolkit/docs/deploy/deploy-a3-mega-cluster) and [GKE GPUDirect-TCPXO](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx).

## Key Notes on Rocky Linux Base Image

- **Use `rocky-linux-8-optimized-gcp-nvidia-580` from project `rocky-linux-accelerator-cloud`** (NOT `rocky-linux-8-optimized-gcp` from `rocky-linux-cloud`). It includes the optimized GCP kernel, gVNIC driver, and NVIDIA 580 driver out of the box.
- **Do not run `dnf update` or change the kernel.** Building the `import_helper` DKMS module requires `kernel-devel-$(uname -r)` to match the running kernel exactly.
- **Module name check:** `lsmod` lists the module with an underscore (`import_helper`), not a hyphen (`import-helper`).
- **Rocky Linux 9 / 10:** The published GPUDirect-TCPXO procedure is validated on Rocky Linux 8 (`rocky-linux-8-optimized-gcp-nvidia-580`).
- **Matched TCPXO component versions (NVIDIA 580 driver):**
  - Default (matches public Rocky doc): RxDM `tcpgpudmarxd-dev:v1.0.21` + NCCL plugin `nccl-plugin-gpudirecttcpx-dev:v1.0.15`
  - Latest R580-compatible release (CUDA 12.8, driver ≥ `580.65.06`): RxDM `tcpgpudmarxd-dev:v1.0.22` + NCCL plugin `nccl-plugin-gpudirecttcpx-dev:v1.0.16`
  - Note: Newer releases (`v1.0.17`/`v1.0.23` and `v1.0.18`/`v1.0.24`, which add CUDA 13.2 and CoMMA profiler) require NVIDIA driver **≥ `595.71.05` (R595)** and are **not** compatible with the R580 host driver (`580.196.07`) in `rocky-linux-8-optimized-gcp-nvidia-580`.

## Scripts Overview

| Script | Purpose |
| --- | --- |
| `set_envs.sh` | Environment configuration (project, zone, networks, image, provisioning mode, TCPXO versions) |
| `create_network.sh` | Creates 1 management VPC + 8 data VPCs (MTU 8244), subnets, and firewall rules (idempotent) |
| `startup_script_rocky.sh` | Rocky Linux 8 host setup (`import_helper` DKMS, Docker, NVIDIA Container Toolkit, NCCL plugin, systemd units for apertures & RxDM) |
| `build_image.sh` | Builds a reusable Rocky Linux 8 TCPXO custom image (~4–5 min on a lightweight builder VM) |
| `create_instance.sh` | Creates A3 Mega VM(s) with 9 gVNICs across `SPOT`, `STANDARD` (or CUD), `FLEX_START`, or `RESERVATION_BOUND` |
| `create_dws_flex.sh` | Creates gang-scheduled (all-or-nothing) multi-node A3 Mega VMs via MIG + DWS Flex-Start resize-request |
| `validate_tcpxo.sh` | Verifies node health (GPUs, 9 NICs/MTU 8244, 8 apertures, `import_helper`, RxDM, NCCL libs) and runs the 2-node NCCL benchmark |
| `cleanup.sh` | Deletes test VMs, MIG/template, and/or VPC networks |

---

## Step 1: Configure Environment Variables

Enter the `rocky-linux8` folder, edit `set_envs.sh` with your GCP project, region, zone, and network prefix, then source it:

```bash
cd rocky-linux8
source set_envs.sh
```

## Step 2: Create the 9 VPC Networks (1 Management + 8 Data, MTU 8244)

A3 Mega requires 9 gVNIC interfaces per VM (1 management + 8 GPU data networks). Run:

```bash
bash create_network.sh
```

This creates:
- `${NETWORK_PREFIX}-mgmt-net` / `${NETWORK_PREFIX}-mgmt-sub` (`192.168.0.0/24`, MTU 8244) with internal all-TCP/UDP/ICMP (required for MPI and test container SSH on port 222) and external SSH/ICMP rules.
- `${NETWORK_PREFIX}-data-net-1..8` / `${NETWORK_PREFIX}-data-sub-1..8` (`192.168.1..8.0/24`, MTU 8244) with internal firewall rules.

## Step 3: Build a Custom Golden Image (Recommended) — OR Skip for Direct Boot

### Option A: Build a Reusable Custom Image (`USE_CUSTOM_IMAGE=true`, default)

Recommended when rolling out multiple A3 Mega nodes (fast boot, pre-pulled containers, pre-built `import_helper` DKMS module, pre-installed `/var/lib/tcpxo/lib64`):

```bash
bash build_image.sh
```

This launches a temporary `n2-standard-8` VM from `rocky-linux-8-optimized-gcp-nvidia-580`, runs `startup_script_rocky.sh`, shuts down, mints an image in family `${CUSTOM_IMAGE_FAMILY}`, and deletes the temporary VM.

### Option B: Direct Boot Without Building a Custom Image

For quick 1–2 node pilots, set `export USE_CUSTOM_IMAGE=false` in `set_envs.sh` (or your shell) and skip `build_image.sh`. `create_instance.sh` will boot directly from `rocky-linux-8-optimized-gcp-nvidia-580` and run `startup_script_rocky.sh` automatically on first boot.

## Step 4: Create A3 Mega VMs

Set `PROVISION_MODE` and `COUNT` in `set_envs.sh` (or override inline) and run `create_instance.sh`:

- **Spot VMs (recommended for testing):**
  ```bash
  PROVISION_MODE=SPOT COUNT=2 bash create_instance.sh
  ```
- **Standard / CUD Reservation:**
  ```bash
  PROVISION_MODE=STANDARD RESERVATION="projects/$PROJECT/reservations/MY_RES" COUNT=2 bash create_instance.sh
  ```
- **Reservation-Bound (DWS Calendar):**
  ```bash
  PROVISION_MODE=RESERVATION_BOUND RESERVATION="projects/$PROJECT/reservations/MY_RES" COUNT=2 bash create_instance.sh
  ```
- **Direct Flex-Start:**
  ```bash
  PROVISION_MODE=FLEX_START MAX_RUN_DURATION=24h VALID_FOR_DURATION=0s COUNT=1 bash create_instance.sh
  ```
- **Gang-Scheduled Multi-Node DWS Flex-Start (MIG resize-request):**
  ```bash
  COUNT=2 MAX_RUN_DURATION=24h bash create_dws_flex.sh
  ```

## Step 5: Validate Node Health & Run 2-Node GPUDirect-TCPXO Benchmark

Copy `validate_tcpxo.sh` to your A3 Mega VM(s) (or SSH in directly):

```bash
VM1="${VM_NAME_PREFIX}-0001"
VM2="${VM_NAME_PREFIX}-0002"

gcloud compute scp validate_tcpxo.sh "${VM1}:~/" --project="${PROJECT}" --zone="${ZONE}"
gcloud compute ssh "${VM1}" --project="${PROJECT}" --zone="${ZONE}" -- "bash ~/validate_tcpxo.sh"
```

Expected host checks:
1. `nvidia-smi` shows 8x NVIDIA H100 80GB GPUs with driver 580.
2. `ip -br link` shows 1 management NIC (`enp0s12`) + 8 data NICs (e.g. `enp6s0f0`..`enp142s0f0` on `rocky-linux-8-optimized-gcp-nvidia-580`), all data NICs at `mtu 8244`. `validate_tcpxo.sh` and `tcpxo_env.sh` auto-detect the exact interface names.
3. `lspci -nn -D | grep 1ae0:0084` shows 8 aperture devices, all bind-mounted under `/dev/aperture_devices/`.
4. `lsmod | grep import_helper` shows `import_helper` loaded and `/dev/dmabuf_import_helper` present.
5. `sudo docker logs rxdm 2>&1 | grep "Buffer manager initialization complete"` confirms RxDM initialized.
6. `/var/lib/tcpxo/lib64` contains `libnccl-net.so`, `libnccl.so`, and `nccl-env-profile.sh`.

### Run the 2-Node NCCL `all_gather_perf` Benchmark (Public Doc Step 4)

On **both** `VM1` and `VM2`, start the official `nccl` test container:

```bash
for vm in "${VM1}" "${VM2}"; do
  gcloud compute scp validate_tcpxo.sh "${vm}:~/" --project="${PROJECT}" --zone="${ZONE}"
  gcloud compute ssh "${vm}" --project="${PROJECT}" --zone="${ZONE}" -- "bash ~/validate_tcpxo.sh --start-nccl"
done
```

On **`VM1`**, execute the 2-node benchmark (auto-detects the 8 data NIC names and control NIC):

```bash
gcloud compute ssh "${VM1}" --project="${PROJECT}" --zone="${ZONE}" -- \
  "bash ~/validate_tcpxo.sh --test ${VM1} ${VM2}"
```

On healthy A3 Mega nodes over GPUDirect-TCPXO, 8 GB `all_gather_perf` achieves ~100–170+ GB/s bus bandwidth (confirming FasTrak / GPUDirect-TCPXO rather than plain TCP fallback).

## Running Workloads Outside Docker (e.g., Apptainer / LSF / Bare-Metal MPI)

Each VM includes `/usr/local/bin/tcpxo_env.sh` and automatically sets `0666` permissions on `/dev/aperture_devices/*/resource*` and `/dev/dmabuf_import_helper` at boot via `mount-aperture.service`:

- Keep GPUs in default (shared) compute mode so RxDM can share GPU access with jobs.
- Source `/usr/local/bin/tcpxo_env.sh` (or wrap the job command with it) so `/var/lib/tcpxo/lib64` is first in `LD_LIBRARY_PATH` and `NCCL_FASTRAK_*` variables match the node's actual interface names.
- For Ubuntu 22.04-based Apptainer images (e.g. `nvcr.io/nvidia/pytorch:24.04-py3`), run in host network namespace with host `/dev` (avoid `--net`, `--contain`, `--containall`) and bind `/var/lib/tcpxo/lib64`:
  ```bash
  apptainer exec --nv -B /var/lib/tcpxo/lib64 pytorch-24.04.sif \
    /var/lib/tcpxo/lib64/tcpxo_env.sh <your-command>
  ```
- During bring-up, add `NCCL_DEBUG=INFO NCCL_NET=FasTrak` to fail fast instead of silently falling back to plain TCP.

## Step 6: Cleanup

```bash
bash cleanup.sh --vms       # Delete A3 Mega VMs (and Flex MIG/template)
bash cleanup.sh --networks  # Delete the 9 VPC networks, subnets, and firewall rules
bash cleanup.sh --all       # Delete everything
```
