{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label. A label value is at
most 63 characters and begins and ends alphanumeric: the cut of a long version
(a branch build's <version>-dev.<branch>.<date>.<time>.<sha>, or the
<version>+<digest> helm-controller installs) can land on any run of ".", "_"
(from "+") and "-", so the whole run is trimmed.
*/}}
{{- define "chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimAll "-._" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "labels.common" -}}
app: {{ include "name" . | quote }}
{{ include "labels.selector" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | quote }}
helm.sh/chart: {{ include "chart" . | quote }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "labels.selector" -}}
app.kubernetes.io/name: {{ include "name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{/* <cluster>-<pool>: the pool's identity everywhere. */}}
{{- define "gpu-node-pool.poolName" -}}
{{- printf "%s-%s" (required "cluster.name is required" .Values.cluster.name) (required "pool.name is required" .Values.pool.name) -}}
{{- end -}}

{{/* Labels the cluster charts set on a pool's objects. */}}
{{- define "gpu-node-pool.poolLabels" -}}
{{ include "labels.common" . }}
cluster.x-k8s.io/cluster-name: {{ .Values.cluster.name | quote }}
cluster.x-k8s.io/watch-filter: capi
giantswarm.io/cluster: {{ .Values.cluster.name | quote }}
giantswarm.io/machine-pool: {{ include "gpu-node-pool.poolName" . | quote }}
giantswarm.io/organization: {{ .Values.cluster.organization | quote }}
{{- end -}}

{{/* The curated accelerator list: accelerator -> EC2 instance family. */}}
{{- define "gpu-node-pool.accelerators" -}}
nvidia-l4: g6
nvidia-a10g: g5
nvidia-t4: g4dn
nvidia-l40s: g6e
{{- end -}}

{{- define "gpu-node-pool.instanceFamily" -}}
{{- $families := include "gpu-node-pool.accelerators" . | fromYaml -}}
{{- get $families .Values.pool.accelerator | required (printf "pool.accelerator %q is not in the curated list" .Values.pool.accelerator) -}}
{{- end -}}

{{/* One KubeadmConfig file entry, content inline as base64. */}}
{{- define "gpu-node-pool.file" -}}
- path: {{ .path }}
  permissions: {{ .permissions | quote }}
  encoding: base64
  content: {{ .content | b64enc }}
{{- end -}}

{{/* A file of the chart, verbatim; `src` names a variant of it. */}}
{{- define "gpu-node-pool.staticFile" -}}
{{- include "gpu-node-pool.file" (dict "path" .path "permissions" .permissions "content" (.ctx.Files.Get (printf "files%s" (.src | default .path)))) -}}
{{- end -}}

{{/* The name of the driver extension as Flatcar's enabled-sysext.conf takes it (`flatcar-<name>.raw` on the release server). */}}
{{- define "gpu-node-pool.nvidiaSysext" -}}
{{- printf "nvidia-drivers-%s" .Values.pool.nvidiaDriver.branch -}}
{{- end -}}

{{/*
The Flatcar version of pool.machineImage (flatcar-<channel>-<version>-kube-...), for the driver extension:
the release server ships flatcar-nvidia-drivers-* from 4344.0.0 on, and the OS fails the boot when it
finds none for its version.
*/}}
{{- define "gpu-node-pool.flatcarVersion" -}}
{{- $image := .Values.pool.machineImage -}}
{{- if not (regexMatch "^flatcar-[a-z]+-[0-9]+\\.[0-9]+\\.[0-9]+-kube-" $image) -}}
{{- fail (printf "pool.nvidiaDriver.source flatcar-sysext needs the Flatcar version of pool.machineImage (flatcar-<channel>-<version>-kube-...), got %q; pool.nvidiaDriver.source image-build builds the driver on any image" $image) -}}
{{- end -}}
{{- $version := regexReplaceAll "^flatcar-[a-z]+-([0-9]+\\.[0-9]+\\.[0-9]+)-kube-.*$" $image "${1}" -}}
{{- if not (semverCompare ">= 4344.0.0" $version) -}}
{{- fail (printf "pool.nvidiaDriver.source flatcar-sysext needs Flatcar 4344.0.0 or newer, the first release shipping the nvidia-drivers extension; pool.machineImage is %s. pool.nvidiaDriver.source image-build builds the driver on this image" $version) -}}
{{- end -}}
{{- $version -}}
{{- end -}}

{{/* A file of the chart rendered with the release's values. */}}
{{- define "gpu-node-pool.templatedFile" -}}
{{- include "gpu-node-pool.file" (dict "path" .path "permissions" .permissions "content" (tpl (.ctx.Files.Get (printf "files%s" (.src | default .path))) .ctx)) -}}
{{- end -}}

{{/* Name of the hash-suffixed KubeadmConfig: a bootstrap change renames it and rolls the nodes. */}}
{{- define "gpu-node-pool.kubeadmConfigName" -}}
{{- printf "%s-%s" (include "gpu-node-pool.poolName" .) (include "gpu-node-pool.kubeadmConfigSpec" . | sha1sum | trunc 5) -}}
{{- end -}}
