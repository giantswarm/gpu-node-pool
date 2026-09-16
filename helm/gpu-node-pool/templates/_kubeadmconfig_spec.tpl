{{/*
The worker bootstrap: the cluster charts' rendered spec for a CAPA Flatcar
Karpenter worker, files inline, the pool's identity and the GPU taint added.
`make verify` diffs it against the newest released cluster-aws.
*/}}
{{- define "gpu-node-pool.kubeadmConfigSpec" -}}
{{- $poolName := include "gpu-node-pool.poolName" . -}}
files:
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/sysctl.d/hardening.conf" "permissions" "0644") }}
{{ include "gpu-node-pool.templatedFile" (dict "ctx" . "path" "/etc/containerd/config.toml" "permissions" "0644") }}
{{- range $registry, $endpoints := .Values.cluster.registryMirrors }}
{{ include "gpu-node-pool.file" (dict "path" (printf "/etc/containerd/certs.d/%s/hosts.toml" $registry) "permissions" "0644" "content" (tpl ($.Files.Get "files/etc/containerd/hosts.toml.tpl") (dict "registry" $registry "endpoints" $endpoints "Template" $.Template))) }}
{{- end }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/selinux/config" "permissions" "0644") }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/selinux/flatcar-containerd-patch.cil" "permissions" "0644") }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/systemd/timesyncd.conf" "permissions" "0644") }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/kubernetes/patches/kubeletconfiguration.yaml" "permissions" "0644") }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/systemd/logind.conf.d/zzz-kubelet-graceful-shutdown.conf" "permissions" "0700") }}
{{- if .Values.teleport.enabled }}
- path: /etc/teleport-join-token
  permissions: "0644"
  contentFrom:
    secret:
      name: {{ .Values.cluster.name }}-teleport-join-token
      key: joinToken
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/opt/teleport-node-role.sh" "permissions" "0755") }}
{{ include "gpu-node-pool.templatedFile" (dict "ctx" . "path" "/etc/teleport.yaml" "permissions" "0644") }}
{{- end }}
{{ include "gpu-node-pool.templatedFile" (dict "ctx" . "path" "/opt/bin/kubelet-aws-config.sh" "permissions" "0755") }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/systemd/system/kubelet-aws-config.service" "permissions" "0644") }}
{{ include "gpu-node-pool.staticFile" (dict "ctx" . "path" "/etc/systemd/system/nvidia-cdi-spec.service" "permissions" "0644") }}
{{ include "gpu-node-pool.templatedFile" (dict "ctx" . "path" "/etc/systemd/network/99-unmanaged-devices.network" "src" (printf "/etc/systemd/network/99-unmanaged-devices.network.%s" .Values.cluster.cilium.ipamMode) "permissions" "0644") }}
{{- if .Values.cluster.proxy.enabled }}
{{- range $unit := list "containerd" "kubelet" "teleport" }}
{{- if or (ne $unit "teleport") $.Values.teleport.enabled }}
{{ include "gpu-node-pool.templatedFile" (dict "ctx" $ "path" (printf "/etc/systemd/system/%s.service.d/http-proxy.conf" $unit) "src" "/etc/systemd/http-proxy.conf" "permissions" "0644") }}
{{- end }}
{{- end }}
{{- end }}
format: ignition
ignition:
  containerLinuxConfig:
    additionalConfig: |
{{ tpl (.Files.Get "files/ignition.yaml") . | trimSuffix "\n" | indent 6 }}
joinConfiguration:
  nodeRegistration:
    kubeletExtraArgs:
    - name: cgroup-driver
      value: systemd
    - name: cloud-provider
      value: external
    - name: healthz-bind-address
      value: 0.0.0.0
    - name: node-ip
      value: ${COREOS_EC2_IPV4_LOCAL}
    - name: node-labels
      value: ip=${COREOS_EC2_IPV4_LOCAL},role=worker,giantswarm.io/machine-pool={{ $poolName }}
    - name: v
      value: "2"
    name: ${COREOS_EC2_HOSTNAME}
    taints:
    - effect: NoExecute
      key: ebs.csi.aws.com/agent-not-ready
    - effect: NoSchedule
      key: nvidia.com/gpu
    - effect: NoExecute
      key: karpenter.sh/unregistered
      value: karpenter
  patches:
    directory: /etc/kubernetes/patches
preKubeadmCommands:
{{- if .Values.cluster.proxy.enabled }}
- export HTTP_PROXY={{ .Values.cluster.proxy.httpProxy }}
- export HTTPS_PROXY={{ .Values.cluster.proxy.httpsProxy }}
- export NO_PROXY="{{ .Values.cluster.proxy.noProxy }}"
- export http_proxy={{ .Values.cluster.proxy.httpProxy }}
- export https_proxy={{ .Values.cluster.proxy.httpsProxy }}
- export no_proxy="{{ .Values.cluster.proxy.noProxy }}"
{{- end }}
- envsubst < /etc/kubeadm.yml > /etc/kubeadm.yml.tmp
- mv /etc/kubeadm.yml.tmp /etc/kubeadm.yml
- systemctl restart containerd
- rm -rf /var/lib/selinux
- cp -a /usr/lib/selinux/policy /var/lib/selinux
- semodule -DB
- semodule -i /etc/selinux/flatcar-containerd-patch.cil
- rm -f /etc/audit/rules.d/80-selinux.rules
- systemctl restart audit-rules
- rm -rf /etc/ssl/certs
- cp -a /usr/share/ca-certificates /etc/ssl/certs
- restorecon -RFv -e /usr /
- mkdir -p /var/log/apiserver
- chcon -R -t container_file_t /var/log/apiserver
{{- end -}}
