{{/*
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation

Common template helpers for the sigul chart.
*/}}

{{- define "sigul.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Base name for all resources. Truncated to 42 characters so that
     every generated name stays within the 63-character DNS label
     limit after suffixing - the longest suffixes in this chart are
     "-pki-bootstrap-egress" / "-admin-toolbox-egress" (21 chars). */}}
{{- define "sigul.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 42 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 42 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 42 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sigul.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ include "sigul.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
sigul.linuxfoundation.org/tenant: {{ .Values.tenant | quote }}
{{- end -}}

{{/* Image references: digest wins over tag. */}}
{{- define "sigul.image.bridge" -}}
{{- if .Values.images.bridge.digest -}}
{{ .Values.images.bridge.repository }}@{{ .Values.images.bridge.digest }}
{{- else -}}
{{ .Values.images.bridge.repository }}:{{ .Values.images.bridge.tag }}
{{- end -}}
{{- end -}}

{{- define "sigul.image.server" -}}
{{- if .Values.images.server.digest -}}
{{ .Values.images.server.repository }}@{{ .Values.images.server.digest }}
{{- else -}}
{{ .Values.images.server.repository }}:{{ .Values.images.server.tag }}
{{- end -}}
{{- end -}}

{{- define "sigul.image.client" -}}
{{- if .Values.images.client.digest -}}
{{ .Values.images.client.repository }}@{{ .Values.images.client.digest }}
{{- else -}}
{{ .Values.images.client.repository }}:{{ .Values.images.client.tag }}
{{- end -}}
{{- end -}}

{{/* Internal (ClusterIP) bridge service name and cluster-DNS FQDN.
     sigul.fullname reserves suffix space (42-char cap), so plain
     suffixing is safe here. */}}
{{- define "sigul.bridge.serviceName" -}}
{{ include "sigul.fullname" . }}-bridge
{{- end -}}

{{/* Headless variant: DNS resolves only when the bridge pod is Ready
     (exec-probe based), enabling a wait gate that never opens a TCP
     connection to the bridge. */}}
{{- define "sigul.bridge.headlessServiceName" -}}
{{ include "sigul.fullname" . }}-bridge-hl
{{- end -}}

{{- define "sigul.bridge.internalFQDN" -}}
{{ include "sigul.bridge.serviceName" . }}.{{ .Release.Namespace }}.svc.cluster.local
{{- end -}}

{{/* Server certificate CN (client validates inner TLS against it). */}}
{{- define "sigul.server.certCN" -}}
sigul-server.{{ include "sigul.bridge.internalFQDN" . }}
{{- end -}}

{{/* Secret names: the contract between bootstrap Job and workloads.
     The admin Secret is deliberately separate from the PKI-coupled
     passwords Secret: PKI regeneration (mode=force) must never
     overwrite the admin credential already hashed into the server's
     persistent database. */}}
{{- define "sigul.secret.caPublic" -}}{{ include "sigul.fullname" . }}-ca-public{{- end -}}
{{- define "sigul.secret.bridgeP12" -}}{{ include "sigul.fullname" . }}-bridge-p12{{- end -}}
{{- define "sigul.secret.serverP12" -}}{{ include "sigul.fullname" . }}-server-p12{{- end -}}
{{- define "sigul.secret.clientP12" -}}{{ include "sigul.fullname" . }}-client-p12{{- end -}}
{{- define "sigul.secret.passwords" -}}{{ include "sigul.fullname" . }}-passwords{{- end -}}
{{- define "sigul.secret.admin" -}}{{ include "sigul.fullname" . }}-admin{{- end -}}
{{- define "sigul.secret.marker" -}}{{ include "sigul.fullname" . }}-pki-complete{{- end -}}
{{- define "sigul.lease.bootstrapLock" -}}{{ include "sigul.fullname" . }}-pki-lock{{- end -}}

{{/* Workload names (referenced by the bootstrap Job for force-mode
     coordinated restarts). */}}
{{- define "sigul.bridge.deploymentName" -}}{{ include "sigul.fullname" . }}-bridge{{- end -}}
{{- define "sigul.server.statefulSetName" -}}{{ include "sigul.fullname" . }}-server{{- end -}}
{{- define "sigul.toolbox.deploymentName" -}}{{ include "sigul.fullname" . }}-admin-toolbox{{- end -}}

{{/* Bootstrap ServiceAccount: generated name, or a caller-supplied
     existing account when creation is disabled. */}}
{{- define "sigul.pkiBootstrap.serviceAccountName" -}}
{{- if .Values.serviceAccounts.pkiBootstrap.create -}}
{{ include "sigul.fullname" . }}-pki-bootstrap
{{- else -}}
{{ required "serviceAccounts.pkiBootstrap.name is required when create=false" .Values.serviceAccounts.pkiBootstrap.name }}
{{- end -}}
{{- end -}}

{{/* Sigul administrator name, validated at render time.

     The value reaches a SQL string literal (files/scripts/db-init.sh
     counts administrators by name), a command-line argument
     (sigul_server_add_admin -n) and a rendered client.conf. A quote,
     backslash, semicolon or newline breaks or subverts at least one
     of those, and none of them can validate their own input usefully
     - by then the release is already deployed.

     Rejecting here fails `helm install`/`template` with the reason,
     before anything is created. The permitted set is deliberately
     narrower than Sigul allows: it covers every realistic account
     name while being inert in all three contexts.

     toString first: the grammar permits all-digit names, and an
     unquoted `adminUser: 123` reaches templates as a number, which
     regexMatch rejects on type rather than on content. Coercing
     keeps the failure mode about the name. */}}
{{- define "sigul.server.adminUser" -}}
{{- $user := required "server.adminUser is required" .Values.server.adminUser -}}
{{- $user = toString $user -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}$" $user) -}}
{{- fail (printf "server.adminUser %q is invalid: it must start with a letter or digit and contain only letters, digits, and . _ @ + - (max 64 characters)" $user) -}}
{{- end -}}
{{ $user }}
{{- end -}}

{{/* StorageClass name: explicit value, or release-derived. The class
     is cluster-scoped while releases are namespace-scoped, so the
     namespace (unique cluster-wide) is the discriminator that makes
     the derived name unique. Release name alone is not enough: the
     per-tenant Argo CD Applications pin the same releaseName and
     differ only by destination namespace. */}}
{{- define "sigul.storageClassName" -}}
{{- if .Values.storageClass.name -}}
{{ .Values.storageClass.name }}
{{- else -}}
{{ printf "%s-%s-server-sc" .Release.Namespace (include "sigul.fullname" .) | trunc 253 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{/* Server volume StorageClass: explicit value wins; otherwise the
     chart-created Retain-policy class when enabled; otherwise the
     cluster default.

     The two settings are alternatives, not layers, so combining them
     is rejected rather than silently resolved. Creating a class and
     then claiming from a different one leaves the created class
     bound to nothing - a cluster-scoped object, owned by a
     namespaced release, that no volume will ever use, while the key
     material lands on whatever the named class provides. Both halves
     look correct in isolation, and neither the claim nor the class
     reports a problem, so nothing surfaces until someone asks which
     class actually holds the signing keys.

     To consume a platform-managed class, set only
     server.persistence.storageClassName and leave storageClass.create
     false. storageClass.name renames what the chart creates; it never
     selects an existing class. */}}
{{- define "sigul.server.storageClassName" -}}
{{- if .Values.server.persistence.storageClassName -}}
{{- $claimed := .Values.server.persistence.storageClassName -}}
{{- if .Values.storageClass.create -}}
{{- $created := include "sigul.storageClassName" . -}}
{{- if ne $created $claimed -}}
{{- fail (printf "storageClass.create is true (creating StorageClass %q) but server.persistence.storageClassName is %q: the created class would go unused. Set storageClass.create=false to consume the existing class %q, or clear server.persistence.storageClassName to claim from the chart-created one." $created $claimed $claimed) -}}
{{- end -}}
{{- end -}}
{{ $claimed }}
{{- else if .Values.storageClass.create -}}
{{ include "sigul.storageClassName" . }}
{{- end -}}
{{- end -}}

{{/* Scheduling (nodeSelector / tolerations / affinity) for the pods
     that handle server-grade key material but are not the server.

     Both default to following server.* rather than to empty. Taints
     repel; they do not attract, so isolating the server onto a
     dedicated tainted pool takes a toleration to permit it there and
     a nodeSelector or affinity to keep it there. A pod left with
     neither does not fail - it schedules somewhere else, which is
     precisely the outcome the pool exists to prevent, and it does so
     silently.

     That default matters most for the bootstrap Job. It generates the
     CA private key and every leaf key in its scratch NSS DB, so a Job
     carrying no toleration is the one pod a tainted server pool
     excludes by construction: the most sensitive workload in the
     chart would be guaranteed to run outside the isolation, on a node
     shared with everything else.

     Set inheritServer: false to place either pod independently. The
     three fields then apply as a set and are not merged with the
     server's - all three left empty means "schedule anywhere", which
     is a deliberate opt-out rather than a default. */}}
{{- define "sigul.scheduling" -}}
{{- $own := .scheduling | default dict -}}
{{- $inherit := ternary $own.inheritServer true (hasKey $own "inheritServer") -}}
{{- $eff := ternary .ctx.Values.server $own $inherit -}}
{{- $out := dict -}}
{{- with $eff.nodeSelector -}}{{- $_ := set $out "nodeSelector" . -}}{{- end -}}
{{- with $eff.tolerations -}}{{- $_ := set $out "tolerations" . -}}{{- end -}}
{{- with $eff.affinity -}}{{- $_ := set $out "affinity" . -}}{{- end -}}
{{- if $out -}}{{ toYaml $out }}{{- end -}}
{{- end -}}

{{/* Restricted-PSS-compliant pod security context (UID/GID 1000). */}}
{{- define "sigul.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
fsGroup: 1000
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "sigul.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/* imagePullSecrets snippet (GHCR packages currently private). */}}
{{- define "sigul.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
