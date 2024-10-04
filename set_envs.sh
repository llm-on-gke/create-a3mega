export PROJECT=<Project_ID>
export IMAGE_PROJECT=<PROJECT_ID to store image>
export PROJECT_NUMBER=<Project Number>
export REGION=<Compute Region>
export ZONE=<Compute Zone>
export NETWORK_PREFIX=<Primary Name Fix>
export PROVISION_MODE=standard #spot or standard, DWS need to use standard
export COUNT=1 #number of VMs to create
export RESERVATION=projects/$PROJECT/reservations/a3-mega-us-central1-c # optional for DWS future reservation name
export OS_TYPE=Ubuntu #Debian or Ubuntu 
export BASE_IMAGE=ubuntu-2204-jammy-v20240904 #debian-12-bookworm-v20240515

