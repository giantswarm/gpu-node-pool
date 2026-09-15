server = "https://{{ .registry }}"
{{- range .endpoints }}
[host."https://{{ . }}"]
  capabilities = ["pull", "resolve"]
{{- end }}
