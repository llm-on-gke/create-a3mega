#!/bin/bash
set -eu

PROJECT_ID=northam-ce-mlai-tpu
NETWORK_PREFIX=deshaw-test
REGION=asia-northeast1
#Main network and subnet
gcloud compute networks create $NETWORK_PREFIX-mgmt-net \
  --project=$PROJECT_ID \
  --subnet-mode=custom \
  --mtu=8244

gcloud compute networks subnets create $NETWORK_PREFIX-mgmt-sub \
  --project=$PROJECT_ID \
  --network=$NETWORK_PREFIX-mgmt-net \
  --region=$REGION \
  --range=192.168.0.0/24

gcloud compute firewall-rules create $NETWORK_PREFIX-mgmt-internal \
 --project=$PROJECT \
 --network=$NETWORK_PREFIX-mgmt-net \
 --action=ALLOW \
 --rules=tcp:0-65535,udp:0-65535,icmp \
 --source-ranges=192.168.0.0/16

gcloud compute firewall-rules create $NETWORK_PREFIX-mgmt-external-ssh \
 --project=$PROJECT_ID \
 --network=$NETWORK_PREFIX-mgmt-net \
 --action=ALLOW \
 --rules=tcp:22 \
 --source-ranges=192.168.0.0/16

for N in $(seq 1 8); do
gcloud compute networks create $NETWORK_PREFIX-net-$N \
    --subnet-mode=custom \
    --mtu=8244

gcloud compute networks subnets create $NETWORK_PREFIX-gpunet-$N-subnet \
    --network=$NETWOR_PREFIX-net-$N \
    --region=$REGION \
    --range=192.168.$N.0/24

gcloud compute firewall-rules create $NETWORK_PREFIX-internal-$N \
  --network=#PROJECT_ID-net-$N \
  --action=ALLOW \
  --rules=tcp:0-65535,udp:0-65535,icmp \
  --source-ranges=192.168.0.0/16
done