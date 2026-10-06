#!/bin/bash
# Download the content of pool.prefetchImages into containerd without unpacking it.
#
# The content lands in a namespace of its own, `prefetch`, not the kubelet's
# `k8s.io`: the CRI plugin lists every image of `k8s.io`, so a fetched image there
# would read as present, the kubelet would skip its pull, and the unpack would run
# inside the container's creation, under the kubelet's runtime request timeout.
# containerd shares committed content across namespaces (its default
# content_sharing_policy, `shared`), so the kubelet's pull of the same reference
# finds every blob present, downloads nothing and unpacks. The image record in
# `prefetch` keeps the blobs from containerd's garbage collection.
#
# The registry hosts of /etc/containerd/certs.d apply as they do to the kubelet's
# pulls. A failed fetch is retried; one that keeps failing leaves the kubelet's pull
# to download the image as it would without this unit, and the unit fails, so the
# journal and `systemctl --failed` name the image.
set -u

status=0
{{- range .Values.pool.prefetchImages }}
fetched=false
for attempt in 1 2 3 4 5; do
  if ctr --namespace prefetch content fetch --hosts-dir /etc/containerd/certs.d {{ . | quote }} > /dev/null; then
    echo "fetched {{ . }} (attempt ${attempt})"
    fetched=true
    break
  fi
  sleep $((attempt * 5))
done
if [ "${fetched}" != true ]; then
  echo "failed to fetch {{ . }}" >&2
  status=1
fi
{{- end }}
exit "${status}"
