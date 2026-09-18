#!/usr/bin/env bash
# make verify: goldens per accelerator with and without teleport, the render's
# shape, the KarpenterMachinePool against the CRD the installation serves, the
# prewarm Job, the zone pin, the chart's refusals, and the bootstrap diff against
# the pinned cluster-aws (hack/oracle). `hack/verify.sh update` rewrites the goldens.
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
  for teleport in true false; do
    render --set "pool.accelerator=$accelerator" --set "teleport.enabled=$teleport" > "$work/render.yaml"
    python3 hack/check_render.py --namespace "$namespace" < "$work/render.yaml"
    python3 hack/check_crd.py "$crd" < "$work/render.yaml"
    compare "$fixture/goldens/$accelerator-teleport-$teleport.yaml" "$work/render.yaml"
  done
done

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

helm template test-wc "$(oracle cluster-aws)" -n "$namespace" -f hack/oracle/values.yaml > "$work/oracle.yaml"
render > "$work/ours.yaml"
python3 hack/bootstrap_diff.py "$work/oracle.yaml" "$work/ours.yaml" "$release" hack/oracle/whitelist.yaml || status=1

exit $status
