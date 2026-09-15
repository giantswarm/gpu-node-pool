#!/usr/bin/env bash
# make verify: goldens per accelerator with and without teleport, the render's
# shape, and the bootstrap diff against the pinned cluster-aws (hack/oracle).
# `hack/verify.sh update` rewrites the goldens.
set -euo pipefail
cd "$(dirname "$0")/.."

chart=helm/gpu-node-pool
fixture=hack/fixture
release=test-wc-gpu00
namespace=org-giantswarm
mode=${1:-verify}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

render() {
  helm template "$release" "$chart" -n "$namespace" -f "$fixture/values.yaml" "$@"
}

status=0
for accelerator in nvidia-l4 nvidia-a10g nvidia-t4 nvidia-l40s; do
  for teleport in true false; do
    golden="$fixture/goldens/$accelerator-teleport-$teleport.yaml"
    render --set "pool.accelerator=$accelerator" --set "teleport.enabled=$teleport" > "$work/render.yaml"
    python3 hack/check_render.py < "$work/render.yaml"
    if [ "$mode" = update ]; then
      cp "$work/render.yaml" "$golden"
    elif ! diff -u "$golden" "$work/render.yaml"; then
      echo "golden $golden differs; run 'make goldens' if the change is intended" >&2
      status=1
    fi
  done
done

version=$(python3 -c 'import yaml,sys; print(next(d["version"] for d in yaml.safe_load(open(sys.argv[1]))["dependencies"] if d["name"] == "cluster-aws"))' hack/oracle/Chart.yaml)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/gpu-node-pool/cluster-aws-$version
if [ ! -d "$cache/cluster-aws" ]; then
  mkdir -p "$cache"
  curl -sfL "https://giantswarm.github.io/cluster-catalog/cluster-aws-$version.tgz" | tar -xz -C "$cache"
fi
helm template test-wc "$cache/cluster-aws" -n "$namespace" -f hack/oracle/values.yaml > "$work/oracle.yaml"
render > "$work/ours.yaml"
python3 hack/bootstrap_diff.py "$work/oracle.yaml" "$work/ours.yaml" "$release" hack/oracle/whitelist.yaml || status=1

exit $status
