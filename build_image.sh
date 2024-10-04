#!/bin/bash
set -eu
SYS_SUBNET=$NETWORK_PREFIX-mgmt-sub
#RESERVATION=projects/hpc-toolkit-gsc/reservations/a3-mega-us-central1-c
#RESERVATION=a3-mega-us-central1-c
#PLACEMENT_POLICY_NAME=a3-mega-md2-us-central1

IMAGE_PROJECT=debian-cloud
STARTUP_SCRIPT=startup_script.sh
if [[ "$OS_TYPE" == "Ubuntu" ]]; then
  IMAGE_PROJECT=ubuntu-os-cloud #debian-cloud
  STARTUP_SCRIPT=startup_script_ubuntu.sh #startup_script.sh
fi

VM_NAME=${BASE_IMAGE}-tcpxo-$(date +%Y%m%d%H%M%Sz)

gcloud compute instances create \
  ${VM_NAME} \
  --project=$PROJECT \
  --no-boot-disk-auto-delete \
  --image=$BASE_IMAGE \
  --image-project=$IMAGE_PROJECT \
  --zone=$ZONE \
  --machine-type=c2-standard-8 \
  --preemptible \
  --maintenance-policy=TERMINATE \
  --restart-on-failure \
  --network-interface=nic-type=GVNIC,subnet=${SYS_SUBNET} \
  --metadata=enable-oslogin=true \
  --provisioning-model=SPOT \
  --service-account=$PROJECT_NUMBER-compute@developer.gserviceaccount.com \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --metadata-from-file=startup-script=$STARTUP_SCRIPT \
  --boot-disk-size=200 \
  --boot-disk-type=pd-ssd \
  --labels=goog-ec-src=vm_add-gcloud


start=$(date +%s)

set +e
gcloud compute instances describe ${VM_NAME} --zone=${ZONE}  | grep TERMINATED
status=$?
while [ $status -eq "1" ]; do
  echo "Waiting for instance ${VM_NAME} to terminate"
  current=$(date +%s)
  if [[ $((current-start)) -gt 3600 ]]; then
    echo "Exiting. Failed to build after 1 hour"
    exit 1
  fi
  sleep 30
  gcloud compute instances describe ${VM_NAME} --zone=${ZONE}  | grep TERMINATED
  status=$?
done

set -x
gcloud -q compute images create ${VM_NAME} --source-disk=${VM_NAME} --source-disk-zone=${ZONE} --family ${BASE_IMAGE}-tcpxo

# Cleanup
gcloud -q compute instances delete --delete-disks=all --zone=${ZONE} ${VM_NAME}
