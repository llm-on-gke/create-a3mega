#!/bin/bash
set -eu
SYS_SUBNET=$NETWORK_PREFIX-mgmt-sub
GPU0_SUBNET=$NETWORK_PREFIX-gpunet-1-subnet
GPU1_SUBNET=$NETWORK_PREFIX-gpunet-2-subnet
GPU2_SUBNET=$NETWORK_PREFIX-gpunet-3-subnet
GPU3_SUBNET=$NETWORK_PREFIX-gpunet-4-subnet
GPU4_SUBNET=$NETWORK_PREFIX-gpunet-5-subnet
GPU5_SUBNET=$NETWORK_PREFIX-gpunet-6-subnet
GPU6_SUBNET=$NETWORK_PREFIX-gpunet-7-subnet
GPU7_SUBNET=$NETWORK_PREFIX-gpunet-8-subnet

#RESERVATION=projects/hpc-toolkit-gsc/reservations/a3-mega-us-central1-c
#RESERVATION=a3-mega-us-central1-c
#PLACEMENT_POLICY_NAME=a3-mega-md2-us-central1

# --image-family=projects/hpc-toolkit-gsc/global/images/debian-12-bookworm-v20240515-tcpxo \
# --image=debian-12-bookworm-tcpxo-v20240515-20240730212714z \

gcloud alpha compute instances bulk create \
    --count=$COUNT \
    --name-pattern=a3mega-vms-#### \
    --project=$PROJECT \
    --image-project=$IMAGE_PROJECT \
    --image-family=${BASE_IMAGE}-tcpxo \
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
    --provisioning-model=$PROVISION_MODE \
    --zone=$ZONE \
    --on-host-maintenance=TERMINATE \
    --service-account=$PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --boot-disk-size=200 \
    --boot-disk-type=pd-ssd \
    --labels=goog-ec-src=vm_add-gcloud


#--metadata-from-file=startup-script=install_nvidia.sh \