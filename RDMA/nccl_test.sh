# Setup passwordless SSH on nodes in cluster

export NODE0=node-name-0
export NODE1=node-name-1

# On node 0:
ssh-keygen
cp ~/.ssh/id_rsa.pub ~/.ssh/authorized_keys
ssh-copy-id -f -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub $NODE0
cat ~/.ssh/id_rsa.pub

# On node 1:
mkdir ~/.ssh && vi ~/.ssh/authorized_keys
# Copy the key on line above in this file

# On node 0, confirm that this works
ssh-copy-id -f -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub $NODE1
# create hostfile for mpirun
sudo rm /tmp/hostfile
echo $NODE0 port=22 slots=8 | tee -a /tmp/hostfile
echo $NODE1 port=22 slots=8 | tee -a /tmp/hostfile

# Launch mpirun on node 0

# if NCCL_GIB is installed
# set -x
if [ -d /usr/local/gib ]; then
    source /usr/local/gib/scripts/set_nccl_env.sh
    export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/gib/lib:/usr/lib/x86_64-linux-gnu
else
# if nccl-gib is NOT installed - or you rename /usr/local/gib to test this part of the code path
# note that if you test both, you may need to unset the variables that are set in /usr/local/gib/scripts/set_nccl_env.sh
    export NCCL_SOCKET_IFNAME=enp0s19
    export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu
    export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
    export NCCL_IB_CUDA_SUPPORT=1
    export NCCL_CROSS_NIC=0
    export NCCL_NET_GDR_LEVEL=PIX
    export NCCL_P2P_NET_CHUNKSIZE=131072
    export NCCL_NVLS_CHUNKSIZE=524288
    export NCCL_IB_ADAPTIVE_ROUTING=1
    export NCCL_IB_QPS_PER_CONNECTION=4
    export NCCL_IB_TC=52
    export NCCL_IB_FIFO_TC=84
fi
# set +x
# export NCCL_NET_PLUGIN_TELEMETRY_MODE=1
export NCCL_TELEMETRY_MODE=1
export NCCL_PROFILER_LATENCY_FILE=/tmp/latency-%p.txt
export NCCL_PROFILER_SUMMARY_FILE=/tmp/summary-%p.txt

ENV_VARS=$(echo ${!NCCL*} ${!OMPI*} LD_LIBRARY_PATH PATH | sed 's/ / -x /g')
mpirun --hostfile /tmp/hostfile \
    -x $ENV_VARS  \
    --mca plm_rsh_no_tree_spawn 1 \
    --mca orte_keep_fqdn_hostnames 1 \
    --mca btl self,tcp \
    --mca btl_tcp_if_include enp0s19 \
    --bind-to none \
    --mca plm_rsh_agent "ssh -q -o LogLevel=ERROR -o StrictHostKeyChecking=no -p 22" \
    /opt/src/nccl-tests/build/all_gather_perf -b 8M -e 8G -f 2 -g 1 -w 5 --iters 25 -c 1
