
# non GPU networks
for N in $(seq 0 1); do
    # Create custom network
    gcloud compute networks create b200_gvnic_crtr-net-$N \
      --subnet-mode=custom

    # Create subnet within the network
    gcloud compute networks subnets create b200_gvnic_crtr-sub-$N \
      --network=b200_gvnic_crtr-net-$N \
      --region=us-central1-b \
      --range=10.$N.0.0/16

    # Create firewall rule to allow all internal TCP, UDP, and ICMP traffic
    gcloud compute firewall-rules create b200_gvnic_crtr-internal-$N \
      --network=b200_gvnic_crtr-net-$N \
      --action=ALLOW \
      --rules=tcp:0-65535,udp:0-65535,icmp \
      --source-ranges=10.0.0.0/8
  done

# Create SSH firewall rule
gcloud compute firewall-rules create b200-gvnic-crtr-ssh \
  --network=b200-gvnic-crtr-net-0 \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.225.0.0/16

# Create firewall rule to allow ICMP (ping) on network 0
# Assumes that an external IP is only created for vNIC 0
gcloud compute firewall-rules create b200-gvnic-crtr-allow-ping-net-0 \
  --network=b200-gvnic-crtr-net-0 \
  --action=ALLOW \
  --rules=icmp \
  --source-ranges=35.225.0.0/16


# List and verify existing network profiles
gcloud compute network-profiles list

# Create network for CX-7 with RDMA (RoCE) network profile
gcloud compute networks create b200-rdma-crtr-mrdma \
  --network-profile=us-central1-b-vpc-roce \
  --subnet-mode custom

# Create subnets for the RDMA network
for N in $(seq 0 7); do
    gcloud compute networks subnets create b200-rdma-crtr-mrdma-sub-$N \
      --network=b200-rdma-crtr-mrdma \
      --region=us-central1 \
      --range=10.$((N+2)).0.0/16  # Offset to avoid overlap with gVNICs
  done

# Create instance template for B200
gcloud beta compute instance-templates create zt-b200-it \
    --instance-termination-action=DELETE \
    --instance-template-region=us-central1 \
    --machine-type=a4-highgpu-8g \
    --maintenance-policy=TERMINATE \
    --max-run-duration=3600s \
    --provisioning-model=FLEX_START \
    --reservation-affinity=none \
    --image-project=ubuntu-os-accelerator-images \
    --image=ubuntu-accelerator-2204-amd64-with-nvidia-570-v20250624 \
    --network-interface=nic-type=GVNIC,network=b200-gvnic-crtr-net-0,subnet=b200-gvnic-crtr-sub-0 \
--network-interface=nic-type=GVNIC,network=b200-gvnic-crtr-net-1,subnet=b200-gvnic-crtr-sub-1,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-0,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-1,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-2,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-3,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-4,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-5,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-6,no-address \
--network-interface=nic-type=MRDMA,network=b200-rdma-crtr-mrdma,subnet=b200-rdma-crtr-mrdma-sub-7,no-address

# Create B200 BM    
gcloud beta compute instances create zt-b200-bm \
    --source-instance-template=projects/northam-ce-mlai-tpu/regions/us-central1/instanceTemplates/zt-b200-it \
    --zone=us-central1-b
