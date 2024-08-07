#!/bin/bash
set -eu
#Main network and subnet
gcloud compute networks create $NETWORK_PREFIX-mgmt-net \
  --project=$PROJECT \
  --subnet-mode=custom \
  --mtu=8244

gcloud compute networks subnets create $NETWORK_PREFIX-mgmt-sub \
  --project=$PROJECT \
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
 --project=$PROJECT \
 --network=$NETWORK_PREFIX-mgmt-net \
 --action=ALLOW \
 --rules=tcp:22 \
 --source-ranges=35.235.240.0/20

for N in $(seq 1 8); do
gcloud compute networks create $NETWORK_PREFIX-net-$N \
    --subnet-mode=custom \
    --mtu=8244

gcloud compute networks subnets create $NETWORK_PREFIX-gpunet-$N-subnet \
    --network=$NETWORK_PREFIX-net-$N \
    --region=$REGION \
    --range=192.168.$N.0/24

gcloud compute firewall-rules create $NETWORK_PREFIX-internal-$N \
  --network=$NETWORK_PREFIX-net-$N \
  --action=ALLOW \
  --rules=tcp:0-65535,udp:0-65535,icmp \
  --source-ranges=192.168.0.0/16
done