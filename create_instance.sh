#!/bin/bash
set -eu

PROJECT=hpc-toolkit-gsc
IMAGE_PROJECT=hpc-toolkit-gsc
ZONE=us-central1-c
SYS_SUBNET=a3mega-sys-subnet
GPU0_SUBNET=a3mega-cluster-dev-gpunet-0-subnet
GPU1_SUBNET=a3mega-cluster-dev-gpunet-1-subnet
GPU2_SUBNET=a3mega-cluster-dev-gpunet-2-subnet
GPU3_SUBNET=a3mega-cluster-dev-gpunet-3-subnet
GPU4_SUBNET=a3mega-cluster-dev-gpunet-4-subnet
GPU5_SUBNET=a3mega-cluster-dev-gpunet-5-subnet
GPU6_SUBNET=a3mega-cluster-dev-gpunet-6-subnet
GPU7_SUBNET=a3mega-cluster-dev-gpunet-7-subnet
RESERVATION=projects/hpc-toolkit-gsc/reservations/a3-mega-us-central1-c
RESERVATION=a3-mega-us-central1-c
PLACEMENT_POLICY_NAME=a3-mega-md2-us-central1

# --image-family=projects/hpc-toolkit-gsc/global/images/debian-12-bookworm-v20240515-tcpxo \
# --image=debian-12-bookworm-tcpxo-v20240515-20240730212714z \


gcloud alpha compute instances bulk create \
    --count=1 \
    --name-pattern=a3mega-vms-#### \
    --project=$PROJECT \
    --image-project=$IMAGE_PROJECT \
    --image-family=debian-12-bookworm-v20240709-tcpxo \
    --project=hpc-toolkit-gsc \
    --zone=us-central1-c \
    --machine-type=a3-megagpu-8g \
    --maintenance-policy=TERMINATE \
    --restart-on-failure \
    --network-interface=nic-type=GVNIC,subnet=${SYS_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU0_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU1_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU2_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU3_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU4_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU5_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU6_SUBNET} \
    --network-interface=nic-type=GVNIC,subnet=${GPU7_SUBNET} \
    --metadata=enable-oslogin=true \
    --provisioning-model=STANDARD \
    --reservation-affinity=specific \
    --reservation=${RESERVATION} \
    --resource-policies=${PLACEMENT_POLICY_NAME} \
    --maintenance-interval=PERIODIC \
    --service-account=266450182917-compute@developer.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --boot-disk-size=200 \
    --boot-disk-type=pd-ssd \
    --labels=goog-ec-src=vm_add-gcloud


#--metadata-from-file=startup-script=install_nvidia.sh \