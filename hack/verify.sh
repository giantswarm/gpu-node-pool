#!/usr/bin/env bash
# make verify: a golden per accelerator, the render's shape (the Teleport join in
# every render, the proxy drop-ins in a proxied one), the KarpenterMachinePool
# against the CRD the installation serves, the prewarm Job, the zone pin, the lib
# volume's sources, the driver's sources, the chart's refusals, and the bootstrap
# diff against the pinned cluster-aws (hack/oracle). `hack/verify.sh update`
# rewrites the goldens.
set -euo pipefail
cd "$(dirname "$0")/.."

chart=helm/gpu-node-pool
fixture=hack/fixture
values=$chart/ci/ci-values.yaml
release=test-wc-gpu00
namespace=org-giantswarm
mode=${1:-verify}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

render() {
  helm template "$release" "$chart" -n "$namespace" -f "$values" "$@"
}

# oracle <name>: the dependency of hack/oracle/Chart.yaml, downloaded once from
# its catalog into the cache; prints the unpacked chart's directory.
oracle() {
  local name=$1 version repository cache
  read -r version repository < <(python3 -c '
import sys, yaml
dep = next(d for d in yaml.safe_load(open(sys.argv[1]))["dependencies"] if d["name"] == sys.argv[2])
print(dep["version"], dep["repository"])' hack/oracle/Chart.yaml "$name")
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/gpu-node-pool/$name-$version
  if [ ! -d "$cache/$name" ]; then
    mkdir -p "$cache"
    curl -sfL "$repository/$name-$version.tgz" | tar -xz -C "$cache"
  fi
  echo "$cache/$name"
}

# compare <golden> <render>: rewrite the golden in update mode, else diff.
compare() {
  if [ "$mode" = update ]; then
    cp "$2" "$1"
  elif ! diff -u "$1" "$2"; then
    echo "golden $1 differs; run 'make goldens' if the change is intended" >&2
    status=1
  fi
}

# refused <message> <render args...>: the render must fail with the message.
refused() {
  local message=$1
  shift
  if render "$@" > /dev/null 2> "$work/refused.txt"; then
    echo "render with $* must be refused: $message" >&2
    status=1
  elif ! grep -q "$message" "$work/refused.txt"; then
    echo "render with $* failed without '$message':" >&2
    cat "$work/refused.txt" >&2
    status=1
  fi
}

crd=$(oracle aws-resolver-rules-operator)/templates/infrastructure.cluster.x-k8s.io_karpentermachinepools.yaml

for accelerator in nvidia-l4 nvidia-a10g nvidia-t4 nvidia-l40s; do
  render --set "pool.accelerator=$accelerator" > "$work/render.yaml"
  python3 hack/check_render.py --namespace "$namespace" --lib-source instance-store --nvidia-driver flatcar-sysext < "$work/render.yaml"
  python3 hack/check_crd.py "$crd" < "$work/render.yaml"
  compare "$fixture/goldens/$accelerator.yaml" "$work/render.yaml"
done

# cluster.proxy routes containerd, kubelet and the Teleport join through the
# cluster's HTTP proxy, a drop-in per unit; the goldens above hold that none
# renders without it.
proxy=(--set cluster.proxy.enabled=true --set cluster.proxy.httpProxy=http://proxy.example.com:3128 --set cluster.proxy.httpsProxy=http://proxy.example.com:3128 --set cluster.proxy.noProxy=localhost)
render "${proxy[@]}" > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --proxy < "$work/render.yaml"
python3 hack/check_crd.py "$crd" < "$work/render.yaml"

# The prewarm Job renders for the installation's own pool (the fixture's
# management cluster is `test`, so it is opted in) and nowhere else, under the
# platform's PriorityClass by default or the one named -- never a PriorityClass of
# its own: check_render.py holds every object of the render to the release namespace.
prewarm=(--set pool.prewarm.enabled=true --set cluster.managementCluster=test-wc)
render "${prewarm[@]}" > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --prewarm agent-platform-prewarm-placeholder < "$work/render.yaml"
python3 hack/check_crd.py "$crd" < "$work/render.yaml"
render "${prewarm[@]}" --set pool.prewarm.priorityClassName=pool-placeholder > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --prewarm pool-placeholder < "$work/render.yaml"
# --show-only ends with blank lines; the golden ends with one newline, as end-of-file-fixer wants it.
printf '%s\n' "$(render "${prewarm[@]}" --show-only templates/prewarm.yaml)" > "$work/prewarm.yaml"
compare "$fixture/goldens/prewarm.yaml" "$work/prewarm.yaml"
refused "pool.prewarm needs the release on the cluster the pool joins" --set pool.prewarm.enabled=true
refused "pool.prewarm.priorityClassName names the PriorityClass" "${prewarm[@]}" --set pool.prewarm.priorityClassName=
refused "exceeds 0.25 MiB/s per IOPS" --set pool.volumes.libThroughput=1000 --set pool.volumes.libIops=3000

# pool.zones pins every node of the pool to the named zones: a
# topology.kubernetes.io/zone requirement on the NodePool template. The default
# goldens above hold that an empty list renders none.
zones=(--set 'pool.zones={eu-central-1b}')
render "${zones[@]}" > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --zones eu-central-1b < "$work/render.yaml"
python3 hack/check_crd.py "$crd" < "$work/render.yaml"
printf '%s\n' "$(render "${zones[@]}" --show-only templates/karpentermachinepool.yaml)" > "$work/zones.yaml"
compare "$fixture/goldens/zones.yaml" "$work/zones.yaml"

# pool.volumes.libSource: the goldens above hold the default, the node's instance
# store as /var/lib (the unit formatting it, no lib filesystem entry, no lib block
# device mapping, Karpenter's instanceStorePolicy). ebs renders the provisioned gp3
# lib volume -- the objects as they were before the instance store.
ebs=(--set pool.volumes.libSource=ebs)
render "${ebs[@]}" > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --lib-source ebs --nvidia-driver flatcar-sysext < "$work/render.yaml"
python3 hack/check_crd.py "$crd" < "$work/render.yaml"
compare "$fixture/goldens/lib-ebs.yaml" "$work/render.yaml"

# pool.nvidiaDriver: the goldens above hold the default, Flatcar's prebuilt
# extension (the enabled-sysext line, nvidia.service masked, the CDI unit ordered
# after the extension). image-build is the bootstrap as it was before the
# extension, the build at boot; a mirror moves the download of the extension image
# to Ignition. An image older than the first release shipping the extension is
# refused, as is one whose name carries no Flatcar version; image-build renders on any image.
build=(--set pool.nvidiaDriver.source=image-build)
render "${build[@]}" > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --nvidia-driver image-build < "$work/render.yaml"
printf '%s\n' "$(render "${build[@]}" --show-only templates/kubeadmconfig.yaml)" > "$work/nvidia-driver-image-build.yaml"
compare "$fixture/goldens/nvidia-driver-image-build.yaml" "$work/nvidia-driver-image-build.yaml"
mirror=https://mirror.example.com/flatcar/amd64-usr/4593.2.5
render --set "pool.nvidiaDriver.baseURL=$mirror/" > "$work/render.yaml"
python3 hack/check_render.py --namespace "$namespace" --nvidia-driver flatcar-sysext --sysext-url "$mirror/flatcar-nvidia-drivers-570.raw" < "$work/render.yaml"
printf '%s\n' "$(render --set "pool.nvidiaDriver.baseURL=$mirror/" --show-only templates/kubeadmconfig.yaml)" > "$work/nvidia-driver-mirror.yaml"
compare "$fixture/goldens/nvidia-driver-mirror.yaml" "$work/nvidia-driver-mirror.yaml"
refused "needs Flatcar 4344.0.0 or newer" --set pool.machineImage=flatcar-stable-4230.2.1-kube-1.33.1-tooling-1.27.0-gs
refused "needs the Flatcar version of pool.machineImage" --set pool.machineImage=ubuntu-2404-kube-1.33.1-gs
render "${build[@]}" --set pool.machineImage=ubuntu-2404-kube-1.33.1-gs > /dev/null

helm template test-wc "$(oracle cluster-aws)" -n "$namespace" -f hack/oracle/values.yaml > "$work/oracle.yaml"
render > "$work/ours.yaml"
python3 hack/bootstrap_diff.py "$work/oracle.yaml" "$work/ours.yaml" "$release" hack/oracle/whitelist.yaml || status=1

exit $status
