[![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/gpu-node-pool/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/gpu-node-pool/tree/main)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/giantswarm/gpu-node-pool/badge)](https://securityscorecards.dev/viewer/?uri=github.com/giantswarm/gpu-node-pool)

# gpu-node-pool

A GPU node pool on an existing Giant Swarm cluster is today a `nodePools` entry in the cluster's values: a pull
request against the cluster's definition, re-rendered by the cluster's release on every upgrade, and out of reach for
the Agent Platform — App CRs are deprecated, no one may edit a cluster's App CR or HelmRelease, and the platform's
Models pages have nothing to add GPU capacity with. Depending on the shared `cluster` chart or copying the cluster's
own worker pool both bind the pool to one cluster release: the first renders the release's containerd Secret under
the same name and hook Jobs that act on the cluster's own objects, the second has to be re-derived on every cluster
upgrade and never gets a lifecycle of its own.

This chart makes a GPU node pool **its own Cluster API release with its own bootstrap and lifecycle**: one Flux
HelmRelease per pool in `org-<org>`, rendering for an existing Cluster API cluster named in its values a
`MachinePool`, a hash-named `KubeadmConfig` carrying the chart's own worker bootstrap (the rendered CAPA Flatcar
Karpenter worker spec with its files inline, no chart-owned Secrets), and a `KarpenterMachinePool` in the GPU shape
(instance families from a curated accelerator list, the `nvidia.com/gpu` taint, scale to zero). The pool pins its own
Kubernetes version and machine image — never newer than the control plane — so a cluster upgrade never touches it,
and it is deleted with the cluster through Cluster API's owner references. Consumers are cluster-manager
(`create_node_pool`, `delete_node_pool`) and the Dev Portal's *Add GPU node pool* dialog. Decided in
[bumblebee-plans#46](https://github.com/giantswarm/bumblebee-plans/pull/46) (D3); tracked in
[giantswarm/giantswarm#37713](https://github.com/giantswarm/giantswarm/issues/37713).

## Status

The repository carries the chart's skeleton and CI. The templates, the values contract and the bootstrap oracle
(`make verify` against the newest `cluster-aws`) follow in giantswarm/giantswarm#37713.

## Installing

The chart is released to the Giant Swarm catalog (`oci://gsoci.azurecr.io/giantswarm/gpu-node-pool`) and installed
as a Flux `HelmRelease` with an exactly pinned chart version — a bootstrap change rolls GPU nodes, so bumps are
explicit.
