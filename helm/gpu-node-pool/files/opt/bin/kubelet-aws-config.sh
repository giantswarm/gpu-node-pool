#!/usr/bin/env bash
set -euo pipefail

err_report() {
	echo "ERROR: ${0} failed on line ${1}"
}
trap 'err_report ${LINENO}' ERR

# kubelet default
max_pods={{ .Values.cluster.kubelet.maxPods }}

# max pods can't be greater than the number of available IPs in nodeCidrMaskSize
# This is calculated using the maxPodsAbsolute helper from _helpers.tpl
max_pods_absolute={{ .Values.cluster.kubelet.maxPods }}
if (($max_pods > $max_pods_absolute)); then
	max_pods=$max_pods_absolute
fi

# Use a unique suffix so this can't accidentaly use the same patch filenames as the `cluster` chart.
cat > /tmp/kubeletconfiguration1awsconfig+json.yaml <<EOF
- op: replace
  path: /maxPods
  value: ${max_pods}
EOF
mv /tmp/kubeletconfiguration1awsconfig+json.yaml /etc/kubernetes/patches/kubeletconfiguration1awsconfig+json.yaml
