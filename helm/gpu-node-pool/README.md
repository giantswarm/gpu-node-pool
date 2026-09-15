# gpu-node-pool

A GPU node pool as its own Cluster API release for an existing Giant Swarm cluster — MachinePool, KubeadmConfig and KarpenterMachinePool with their own worker bootstrap.

**Homepage:** <https://github.com/giantswarm/gpu-node-pool>

## Source Code

* <https://github.com/giantswarm/gpu-node-pool>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster.name | string | `""` | Name of the existing Cluster API cluster the pool is created for. |
| pool.name | string | `""` | Name of the node pool within the cluster. |
