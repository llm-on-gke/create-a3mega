# create-a3mega

## Manual Debian-Based Image / VM Creation for GPUDirect-TCPXO

These are best-effort instructions for manually creating a Debian-12 based
custom image that has all pieces set up for using GPUDirect-TCPXO. They are
meant to provide documentation of all the necessary components. We suggest
fully understanding these components prior to using.

Note: This is not an officially supported path. For A3-Mega VMs we suggest using
the Cluster Toolkit to [deploy a Slurm
cluster](https://cloud.google.com/cluster-toolkit/docs/deploy/deploy-a3-mega-cluster)
with all these same features, or use
[GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx).

1. Setting environment variables. First set the following environment variables, update set_envs.sh

```
export PROJECT=<Project_ID>
export IMAGE_PROJECT=<PROJECT_ID to store image>
export PROJECT_NUMBER=<Project Number>
export REGION=<Compute Region>
export ZONE=<Compute Zone>
export NETWORK_PREFIX=<Primary Name Prefix>
export PROVISION_MODE=standard #spot or standard, DWS need to use standard
export COUNT=1
export RESERVATION=projects/$PROJECT/reservations/a3-mega-us-central1-c # optional for DWS future reservation name
export OS_TYPE=Debian #Debian or Ubuntu
```
Then run the command to source set_envs.sh
```
source set_envs.sh
```
2. (Optional), Creating the A3-Mega VPC/subnets for the GPU-GPU Communication
All the VMs will need connect to 9 subnets( 1 for default network, 8 for GPU direct TCXPO)

You can run the following script to create the main network VPC and 8 gpu network VPC
```
bash create_netwwork.sh
```


3. Run image building process. This is similar in nature to what a solution like
Packer would do. Creates an instance, runs a startup script that installs a set
of software, stops the instance, and creates a compute image from the image
disk.

```
bash build-image.sh
```

You should see something like the following, and this will take ~10-20 minutes,
largely due to the time to compile NCCL (which is optional but typically used in
ML/AI workloads).

```
NAME                                                ZONE           MACHINE_TYPE   PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP   STATUS
debian-12-bookworm-v20240709-tcpxo-20240806194448z  us-central1-c  c2-standard-8               XX.XX.XX.XX  XX.XX.XX.XX  RUNNING
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
Waiting for instance debian-12-bookworm-v20240709-tcpxo-20240806194448z to terminate
...
status: TERMINATED
+ gcloud -q compute images create debian-12-bookworm-v20240709-tcpxo-20240806195851z --source-disk=debian-12-bookworm-v20240709-tcpxo-20240806195851z --source-disk-zone=us-central1-c --family debian-12-bookworm-v20240709-tcpxo
Created [https://www.googleapis.com/compute/v1/projects/<your-project>/global/images/debian-12-bookworm-v20240709-tcpxo-20240806195851z].
NAME                                                PROJECT          FAMILY                              DEPRECATED  STATUS
debian-12-bookworm-v20240709-tcpxo-20240806195851z  <your-project>  debian-12-bookworm-v20240709-tcpxo              READY
+ gcloud -q compute instances delete --delete-disks=all --zone=us-central1-c debian-12-bookworm-v20240709-tcpxo-20240806195851z
Updated [https://www.googleapis.com/compute/v1/projects/<your-project>/zones/us-central1-c/instances/debian-12-bookworm-v20240709-tcpxo-20240806195851z].
Deleted [https://www.googleapis.com/compute/v1/projects/<your-project>/zones/us-central1-c/instances/debian-12-bookworm-v20240709-tcpxo-20240806195851z].
```

At this point you have a new custom OS that can be used to create VMs with.


4. Creating A3-Mega VMs. Now that we have the new VM image, we'll use it to
launch 2 test A3-Mega VMs. First set these variables to match the VPCs that
you created.

Check the set_envs.sh, with correct number of VMS,
export COUNT=XX. 
To create the instances with different options, run the shell scripts:

For CUD reservations:
```
source set_envs.sh
bash create_cud_reservation.sh
```

For SPOT:
```
bash create_instances.sh
```
For DWS Calendar mode:
```
bash create_dws_calendar.sh
```
For DWS Flex mode:
```
bash create_dws_flex.sh
```

This uses the gcloud compute instances bulk create API.


5. Test basic VM functionality buy running the following:

```
sudo systemctl status --failed
```

#FIXME
Note: At the moment I have seen the following is occasionally needed:

```
sudo systemctl restart install-nccl-net.service
```

This has something to do with when the GPU devices become visible, but we have
not tracked it down yet.

Check that the RxDM is running:

```
$ sudo docker ps
CONTAINER ID   IMAGE                                                                    COMMAND                  CREATED       STATUS       PORTS     NAMES
09a7c2592e8a   us-docker.pkg.dev/gce-ai-infra/gpudirect-tcpxo/tcpgpudmarxd-dev:v1.0.9   "bash /fts/entrypoin…"   7 hours ago   Up 7 hours             receive-datapath-manager
```

and that it properly initilized:

```
$ sudo docker logs receive-datapath-manager 2>&1 | grep "Buffer manager initialization completed."
I0806 16:03:38.959646      88 fastrak_gpumem_manager.cu.cc:284] Buffer manager initialization completed.
```

Check that the aperture devices are present:

```
$ ls /dev/aperture_devices/
0000:06:00.1  0000:07:00.1  0000:0d:00.1  0000:0e:00.1  0000:86:00.1  0000:87:00.1  0000:8d:00.1  0000:8e:00.1
```

Check that the NCCL Net Library was installed:

```
$ ls /var/lib/tcpxo/lib64
a3plus_guest_config.textproto  libnccl-net.so           libnccl-tcpx.so   libnccl-tuner.so  libnccl.so.2       nccl-env-profile.sh
a3plus_tuner_config.textproto  libnccl-net_internal.so  libnccl-tcpxo.so  libnccl.so        libnccl.so.2.21.5
```

# Running multi-node workloads

    1. Set up basic SSH authentication.
    2. On the first node, create an ssh key with `ssh-keygen`, accepting all the defaults.
    3. For all other nodes, create a `/.ssh/authorized_keys` file with the contents
       of `~/.ssh/id_rsa.pub` from the first node.
    4. Test ssh with `ssh <other-node>`, which should succeed after accepting the host key fingerprint.
    5. Create an SSH Hostfile at ~/hostfile, with content such as:

        a3mega-vms-0001 slots=8
        a3mega-vms-0002 slots=8

    6. Test mpi with the following noting the mpirun mca parameters to
       force mpi comms over the system network interface, enp0s12

```
$ mpirun --mca btl self,tcp --mca btl_tcp_if_include enp0s12  --hostfile ~/hostfile -np 16 -npernode 8 hostname
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0001
a3mega-vms-0002
a3mega-vms-0002
a3mega-vms-0002
a3mega-vms-0002
a3mega-vms-0002
a3mega-vms-0002
a3mega-vms-0002
a3mega-vms-0002
```

## Basic NCCL Test

As part of the image build, we installed nccl-tests to /opt/src/nccl-tests. Running the following commands should work out of the box:

```
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/usr/local/lib
NCCL_LIB_DIR=/var/lib/tcpxo/lib64 source /var/lib/tcpxo/lib64/nccl-env-profile.sh
# Grab all relevant env vars to pass to mpirun
HOST_VARS=$(sed 's/ \{1,\}/ -x /g' <<<"${!NCCL*} LD_LIBRARY_PATH")
mpirun -v --mca btl self,tcp --mca btl_tcp_if_include enp0s12 --hostfile ~/hostfile \
    -np 16 \
    -npernode 8 \
    -x ${HOST_VARS} \
    /opt/src/nccl-tests/build/all_reduce_perf -b 8 -e 8G -f 2 -g 1
```

The last line of the output should show 160+ GB/s for the algbw.

## Basic Pytorch Test

Create a file named `hello_pytorch_distributed.py` with the contents:

```
import os
import torch
import torch.distributed as dist

local_rank = int(os.environ["LOCAL_RANK"])
torch.cuda.set_device(local_rank)
dist.init_process_group("nccl")

tensor = torch.ones(2,2).to('cuda')
dist.all_reduce(tensor, op=dist.ReduceOp.SUM)
print(f'Rank {dist.get_rank()} has data {tensor}')

dist.destroy_process_group()
```

Create a python environment and install pytorch (on each node, which would be
easier if these VMs all shared a common filesystem).
```
python3 -m venv env
source env/bin/activate
pip3 install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu121
```

Create a file (on each node), called run_pytorch.sh, with the following
contents:

```
#!/bin/bash
source ~/env/bin/activate
NCCL_LIB_DIR=/var/lib/tcpxo/lib64 source /var/lib/tcpxo/lib64/nccl-env-profile.sh
export NCCL_NET=FasTrak
# Change this if your nodes are named differently
HOST_NODE_ADDR=a3mega-vms-0001:12345
torchrun --nproc_per_node=8 --nnodes=2 --rdzv-backend=c10d --rdzv-endpoint=$HOST_NODE_ADDR hello_pytorch_distributed.py
```

Then launch the test with:

```
NCCL_LIB_DIR=/var/lib/tcpxo/lib64 source /var/lib/tcpxo/lib64/nccl-env-profile.sh
HOST_VARS=$(sed 's/ \{1,\}/ -x /g' <<<"${!NCCL*} LD_LIBRARY_PATH")
mpirun --mca btl self,tcp --mca btl_tcp_if_include enp0s12 --hostfile ~/hostfile -N 2 -npernode 1 -x ${HOST_VARS} bash run_pytorch.sh
```

History
References
Wa
