---
name: sfa-cluster-proxy-backplane-sync
description: "Sync cluster-proxy-addon Helm chart templates and CRDs from stolostron/cluster-proxy into stolostron/backplane-operator. Applies ACM/MCE-specific transformations on top of upstream templates. Trigger phrases: 'sync cluster-proxy to backplane', 'update backplane cluster-proxy charts', 'cluster-proxy backplane sync'."
---

# Cluster-Proxy Backplane Operator Sync

Syncs the cluster-proxy-addon Helm chart templates and CRDs in `stolostron/backplane-operator`
from the upstream source in `stolostron/cluster-proxy`. The upstream chart is at
`charts/cluster-proxy/` and the backplane chart is at
`pkg/templates/charts/toggle/cluster-proxy-addon/`.

## When to Use This Skill

- When `stolostron/cluster-proxy` has received upstream changes that need to flow into
  `backplane-operator`
- After a bulk sync from `open-cluster-management-io/cluster-proxy` into
  `stolostron/cluster-proxy`
- When someone reports the backplane cluster-proxy charts are out of date

## Prerequisites

- A local checkout of `stolostron/cluster-proxy` (the upstream source)
- A workspace worktree of `stolostron/backplane-operator` on a working branch
  (use the `sfa-workspace-clone` skill)
- Both repos should be on their target branches (typically `main`)

---

## Repository Relationship

```
open-cluster-management-io/cluster-proxy  (community upstream)
        |
        v  (GitHub sync fork merge -- see stolostron/cluster-proxy CLAUDE.md)
stolostron/cluster-proxy                  (downstream fork, adds Dockerfiles/CI)
        |
        v  (THIS SKILL -- Helm chart sync with ACM transformations)
stolostron/backplane-operator             (MCE/ACM operator, deploys the chart)
```

The backplane-operator does NOT use the upstream Helm chart directly. It has its own
rendering engine (`pkg/rendering/renderer.go`) that:

- Replaces `.Release.Namespace` with `.Values.global.namespace`
- Replaces image composition helpers with `.Values.global.imageOverrides.cluster_proxy`
- Injects values via a Go struct (`injectValuesOverrides()`), NOT from `values.yaml` on disk
- Adds ACM/OpenShift-specific operational concerns to templates

**Critical:** The `values.yaml` file on disk is NOT read at runtime. The Go `Values` struct
is the sole source of template values, populated by `injectValuesOverrides()` from MCE CRD
fields and environment variables. The `values.yaml` serves only as documentation. Any
`{{ .Values.xxx }}` reference in a template must correspond to a field in the Go struct or
the template will fail with `missingkey=error` at runtime.

### Go Values Struct (what `.Values.xxx` maps to at runtime)

The struct lives in `pkg/rendering/renderer.go`. Key mappings:

| Template path | Source in Go code |
|---|---|
| `.Values.global.namespace` | `mce.Spec.TargetNamespace` |
| `.Values.global.imageOverrides.cluster_proxy` | `RELATED_IMAGE_cluster_proxy` env var |
| `.Values.global.pullPolicy` | `mce.Spec.Overrides.ImagePullPolicy` |
| `.Values.global.pullSecret` | `mce.Spec.ImagePullSecret` |
| `.Values.global.deployOnOCP` | Auto-detected from cluster type |
| `.Values.hubconfig.replicaCount` | `mce.Spec.AvailabilityConfig` (Basic=1, High=2) |
| `.Values.hubconfig.nodeSelector` | `mce.Spec.NodeSelector` |
| `.Values.hubconfig.tolerations` | `mce.Spec.Tolerations` |
| `.Values.hubconfig.proxyConfigs` | `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` env vars |
| `.Values.hubconfig.ocpVersion` | `ACM_HUB_OCP_VERSION` env var |
| `.Values.hubconfig.clusterIngressDomain` | `ACM_CLUSTER_INGRESS_DOMAIN` env var |
| `.Values.enableServiceProxy` | `true` in `injectValuesOverrides()` -- upstream default `false` |
| `.Values.enableKubeApiProxy` | `false` in `injectValuesOverrides()` -- upstream default `true` |
| `.Values.enableImpersonation` | `true` in `injectValuesOverrides()` -- upstream default `true` |

---

## File Inventory

### Upstream Templates -> Backplane Mapping

| Upstream File | Backplane File | Sync Method |
|---|---|---|
| `serviceaccount.yaml` | `serviceaccount.yaml` | Copy + global substitutions |
| `role.yaml` | `role.yaml` | Copy + global substitutions |
| `rolebinding.yaml` | `rolebinding.yaml` | Copy + global substitutions |
| `clusterrolebinding.yaml` | `clusterrolebinding.yaml` | Copy + global substitutions |
| `clusterrole.yaml` | `clusterrole.yaml` | Copy + impersonation override |
| `user-service.yaml` | `user-service.yaml` | Copy + global subs + serving-cert annotation |
| `clustermanagementaddon.yaml` | `clustermanagementaddon.yaml` | Copy + placement hardcode + rolloutStrategy |
| `managedproxyconfiguration.yaml` | `managedproxyconfiguration.yaml` | Copy + entrypoint override + ACM additions |
| `manager-deployment.yaml` | `manager-deployment.yaml` | Copy + global subs + ACM blocks + arg overrides |
| `user-deployment.yaml` | `user-deployment.yaml` | Copy + global subs + ACM blocks + arg overrides |

### NetworkPolicy Templates (upstream exists; ACM replaces toggle path and podSelector label)

| Upstream File | Backplane File | Sync Method |
|---|---|---|
| `cluster-proxy-addon-manager-networkpolicy.yaml` | `cluster-proxy-addon-manager-networkpolicy.yaml` | Copy + toggle path sub + podSelector label override |
| `cluster-proxy-addon-user-networkpolicy.yaml` | `cluster-proxy-addon-user-networkpolicy.yaml` | Copy + toggle path sub |
| `cluster-proxy-proxy-server-networkpolicy.yaml` | `cluster-proxy-proxy-server-networkpolicy.yaml` | Copy + toggle path sub |

### Upstream Files Skipped (managed at higher level by cluster-manager)

| File | Reason |
|---|---|
| `placement.yaml` | ACM uses pre-existing `global` Placement in `open-cluster-management-global-set`, created by cluster-manager |
| `clustersetbinding.yaml` | ACM uses pre-existing ManagedClusterSetBinding, created by cluster-manager |

### Backplane-Only Files (no upstream counterpart -- never modified by sync)

| File | Purpose |
|---|---|
| `anp-route.yaml` | OpenShift Route for ANP proxy-server (TLS passthrough to port 8091) |
| `anp-service.yaml` | Service backing the ANP Route, selects `proxy.open-cluster-management.io/component-name: proxy-server` |
| `user-route.yaml` | OpenShift Route for user-server (TLS reencrypt) |

These three files replace upstream's LoadBalancer/PortForward entrypoint mechanism with
OpenShift-native Routes.

### CRDs

| Upstream Source | Backplane Destination | Method |
|---|---|---|
| `hack/crd/bases/proxy.open-cluster-management.io_managedproxyconfigurations.yaml` | `pkg/templates/crds/cluster-proxy-addon/proxy.open-cluster-management.io_managedproxyconfigurations.yaml` | **Verbatim copy -- no modifications** |

Note: The backplane also ships `proxy.open-cluster-management.io_managedproxyserviceresolvers.yaml`
which does NOT exist in upstream (removed in upstream commit 3eb1cef7, 2026-03-16). This is
an **open item** -- see Open Items section.

---

## Transformation Rules

### Rule 1: Global Substitutions (apply to every copied template)

| Upstream Pattern | Backplane Replacement | Rationale |
|---|---|---|
| `{{ .Release.Namespace }}` | `'{{ .Values.global.namespace }}'` | Backplane rendering engine does not use `.Release.Namespace`; namespace comes from MCE `spec.targetNamespace` via Go struct |
| `{{ include "cluster-proxy-common.clusterProxyImage" . }}` | `{{ .Values.global.imageOverrides.cluster_proxy }}` | Backplane uses a single pre-composed image ref from `RELATED_IMAGE_cluster_proxy` env var instead of upstream's registry/image/tag composition |
| `{{ include "cluster-proxy-common.proxyServerImage" . }}` | `{{ .Values.global.imageOverrides.cluster_proxy }}` | All three upstream image helpers map to one backplane image key |
| `{{ include "cluster-proxy-common.proxyAgentRepositoryImage" . }}` | `{{ .Values.global.imageOverrides.cluster_proxy }}` | Same |
| `{{ $clusterProxyImage }}` | `{{ .Values.global.imageOverrides.cluster_proxy }}` | Variable set from image helper above |
| `{{ $proxyServerImage }}` | `{{ .Values.global.imageOverrides.cluster_proxy }}` | Variable set from image helper above |
| `{{ $proxyAgentImage }}` | `{{ .Values.global.imageOverrides.cluster_proxy }}` | Variable set from image helper above |
| `imagePullPolicy: IfNotPresent` | `imagePullPolicy: '{{ .Values.global.pullPolicy }}'` | Backplane controls pull policy via MCE `spec.overrides.imagePullPolicy` |
| `replicas: {{ .Values.replicas }}` | `replicas: {{ .Values.hubconfig.replicaCount }}` | Controlled by MCE `spec.availabilityConfig` (Basic=1, High=2) |

Also **remove** the library chart variable declaration lines (they reference `cluster-proxy-common`
which does not exist in the backplane chart):
- `{{- $clusterProxyImage := include "cluster-proxy-common.clusterProxyImage" . }}`
- `{{- $proxyServerImage := include "cluster-proxy-common.proxyServerImage" . }}`
- `{{- $proxyAgentImage := include "cluster-proxy-common.proxyAgentRepositoryImage" . }}`

### Rule 2: ACM Hardcoded Overrides

These replace upstream templated values with ACM-specific hardcoded values. Every override
MUST have a YAML comment in the output template explaining the override.

#### In `manager-deployment.yaml` args:

| Upstream | ACM Override | Comment to add |
|---|---|---|
| `--enable-kube-api-proxy={{ .Values.enableKubeApiProxy }}` | Keep as-is -- `EnableKubeApiProxy` is in Go struct, set to `false` | `# ACM override: upstream default true. ACM sets false via EnableKubeApiProxy in renderer.go (commit bc36de88, Jan 2023).` |
| `--enable-service-proxy={{ .Values.enableServiceProxy }}` | Keep as-is -- `EnableServiceProxy` is in Go struct, set to `true` | `# ACM override: upstream default false. ACM sets true via EnableServiceProxy in renderer.go (commit efb29e7b, Nov 2025).` |
| `--enable-network-policies={{ .Values.networkPolicies.enabled }}` | `--enable-network-policies={{ .Values.global.networkPolicies.enabled }}` | `# ACM override: upstream uses .Values.networkPolicies.enabled; backplane uses .Values.global.networkPolicies.enabled (same value, different path). Controls spoke-side proxy-agent NetworkPolicy deployment.` |
| `--agent-install-namespace={{ .Values.spokeAddonNamespace }}` | `--agent-install-namespace=open-cluster-management-agent-addon` | `# ACM override: upstream default "open-cluster-management-cluster-proxy".` |
| `--image-pull-policy={{ .Values.proxyServer.imagePullPolicy }}` | *(remove arg entirely)* | `# ACM: --image-pull-policy arg removed. Not needed in ACM.` |

Also ADD (not in upstream):
```yaml
            # ACM addition: pass image name to addon manager for agent deployment. Not in upstream.
            - --agent-image-name={{ .Values.global.imageOverrides.cluster_proxy }}
```

#### In `user-deployment.yaml` args (user-server container):

| Upstream | ACM Override | Comment to add |
|---|---|---|
| `--agent-install-namespace={{ .Values.spokeAddonNamespace }}` | `--agent-install-namespace=open-cluster-management-agent-addon` | `# ACM override: upstream default "open-cluster-management-cluster-proxy".` |

#### In `clustermanagementaddon.yaml`:

| Upstream | ACM Override | Comment to add |
|---|---|---|
| `name: {{ .Values.installByPlacement.placementName \| default "cluster-proxy-placement" }}` | `name: global` | `# ACM override: use pre-existing global Placement managed by cluster-manager.` |
| `namespace: {{ .Values.installByPlacement.placementNamespace \| default .Release.Namespace }}` | `namespace: open-cluster-management-global-set` | `# ACM override: global-set namespace managed by cluster-manager.` |

Also ADD under the placement entry (upstream omits because `All` is the API default, but
ACM explicitly sets it to guard against future default changes):
```yaml
        # ACM addition: explicitly set rolloutStrategy even though All is the API default,
        # to guard against future API default changes. Upstream omits this field.
        rolloutStrategy:
          type: All
```

#### In `managedproxyconfiguration.yaml`:

| Upstream | ACM Override | Comment to add |
|---|---|---|
| 3-way entrypoint conditional (Hostname / LoadBalancerService / PortForward) | Always `type: Hostname` with `cluster-proxy-anp.{{ .Values.hubconfig.clusterIngressDomain }}` and `port: 443` | `# ACM override: always Hostname via OpenShift Route. Upstream supports Hostname/LoadBalancerService/PortForward.` |
| `proxyAgent.replicas: {{ .Values.replicas }}` | `replicas: 1` | `# ACM override: proxyAgent replicas hardcoded to 1. Upstream uses {{ .Values.replicas }}.` |

### Rule 3: Upstream Conditionals Removed

These upstream `{{- if }}` blocks reference `.Values.xxx` paths that are not in the Go
struct and whose ACM default is `false`/empty. Remove the entire conditional block and
replace with a comment.

| Upstream Block | ACM Action | Comment to add |
|---|---|---|
| `{{- if .Values.featureGates }}` ... `--feature-gates=ClusterProfile=...` ... `{{- end }}` in `manager-deployment.yaml` | Remove entire block | `# ACM: upstream --feature-gates conditional removed. ClusterProfile not enabled in ACM at this time. Re-add when needed (requires Go struct field for .Values.featureGates in renderer.go).` |
| `{{- if .Values.userServer.enabled }}` ... `userServer:` ... `{{- end }}` in `managedproxyconfiguration.yaml` | Remove entire block | `# ACM: upstream userServer cert rotation removed. ACM uses OpenShift service-ca operator (serving-cert annotation on user-service.yaml) instead. Re-add when needed (requires Go struct field for .Values.userServer in renderer.go).` |

### Rule 4: ACM Pod-Level Additions to Deployments

These blocks are added to both `manager-deployment.yaml` and `user-deployment.yaml`. They
do not exist in upstream. Each block must have a comment.

**Replace upstream unconditional seccompProfile with OCP-version-conditional:**

All backplane-operator charts follow the convention of gating seccompProfile behind an OCP
version check. Even though OCP <4.11 is no longer supported, this convention is kept for
consistency across all charts. To remove it, ALL charts in the operator would need to be
updated together (not just cluster-proxy-addon).

Upstream:
```yaml
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
```

ACM replacement:
```yaml
      # ACM override: upstream always sets seccompProfile unconditionally.
      # ACM gates on OCP version because all backplane-operator charts follow this convention.
      # To align with upstream this conditional should be removed across all charts when
      # OCP <4.11 support is officially dropped operator-wide.
      securityContext:
        runAsNonRoot: true
      {{- if .Values.global.deployOnOCP }}
      {{- if semverCompare ">=4.11.0" .Values.hubconfig.ocpVersion }}
        seccompProfile:
          type: RuntimeDefault
      {{- end }}
      {{- end }}
```

**After `serviceAccount[Name]:`, add host security fields:**
```yaml
      # ACM addition: explicitly deny host-level namespace sharing. Not in upstream.
      hostNetwork: false
      hostPID: false
      hostIPC: false
```

**Before `containers:`, add multi-arch node affinity + pod anti-affinity:**
```yaml
      # ACM addition: multi-arch node affinity + pod anti-affinity for HA. Not in upstream.
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
                - arm64
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 70
            podAffinityTerm:
              topologyKey: topology.kubernetes.io/zone
              labelSelector:
                matchExpressions:
                - key: ocm-antiaffinity-selector
                  operator: In
                  values:
                  - <COMPONENT>
          - weight: 35
            podAffinityTerm:
              topologyKey: kubernetes.io/hostname
              labelSelector:
                matchExpressions:
                - key: ocm-antiaffinity-selector
                  operator: In
                  values:
                  - <COMPONENT>
```

Where `<COMPONENT>` is `cluster-proxy-addon-manager` for manager-deployment and
`cluster-proxy-addon-user` for user-deployment. Add `ocm-antiaffinity-selector: <COMPONENT>`
to pod template metadata labels.

**At end of pod spec, append:**
```yaml
      # ACM addition: image pull secret support. Not in upstream.
      {{- if .Values.global.pullSecret }}
      imagePullSecrets:
      - name: {{ .Values.global.pullSecret }}
      {{- end }}
      # ACM addition: node selector for scheduling control. Not in upstream.
      {{- with .Values.hubconfig.nodeSelector }}
      nodeSelector:
{{ toYaml . | indent 8 }}
      {{- end }}
      # ACM addition: tolerations for scheduling on infra nodes. Not in upstream.
      {{- with .Values.hubconfig.tolerations }}
      tolerations:
      {{- range . }}
      - {{ if .Key }} key: {{ .Key }} {{- end }}
        {{ if .Operator }} operator: {{ .Operator }} {{- end }}
        {{ if .Value }} value: {{ .Value }} {{- end }}
        {{ if .Effect }} effect: {{ .Effect }} {{- end }}
        {{ if .TolerationSeconds }} tolerationSeconds: {{ .TolerationSeconds }} {{- end }}
        {{- end }}
{{- end }}
```

### Rule 5: ACM Container-Level Additions to Deployments

**In every container's `env:` section, after existing env vars:**
```yaml
          # ACM addition: HTTP proxy support for clusters with egress proxy. Not in upstream.
          {{- if .Values.hubconfig.proxyConfigs }}
          - name: HTTP_PROXY
            value: {{ .Values.hubconfig.proxyConfigs.HTTP_PROXY }}
          - name: HTTPS_PROXY
            value: {{ .Values.hubconfig.proxyConfigs.HTTPS_PROXY }}
          - name: NO_PROXY
            value: {{ .Values.hubconfig.proxyConfigs.NO_PROXY }}
          {{- end }}
```

**In `manager-deployment.yaml` manager container, before `securityContext`:**
```yaml
          # ACM addition: resource requests for QoS. Not in upstream.
          resources:
            requests:
              cpu: 25m
              memory: 128Mi
```

**In `user-deployment.yaml` user-server container, before `securityContext`:**
```yaml
          # ACM addition: resource requests for QoS. Not in upstream.
          resources:
            requests:
              cpu: 25m
              memory: 256Mi
          # ACM addition: liveness probe for health monitoring. Not in upstream.
          livenessProbe:
            httpGet:
              path: /healthz
              scheme: HTTP
              port: 8000
            initialDelaySeconds: 2
            periodSeconds: 10
          # ACM addition: named port for Route targetPort reference. Not in upstream.
          ports:
            - name: user-port
              containerPort: 9092
              protocol: TCP
```

### Rule 6: ACM Additions to `managedproxyconfiguration.yaml`

**Under `proxyServer:`, after entrypoint:**
```yaml
    # ACM addition: keepalive to prevent idle proxy-agent connections from dropping. Not in upstream.
    additionalArgs:
      - "--keepalive-time=30s"
    # ACM addition: nodePlacement for proxy-server pod scheduling. Not in upstream.
    nodePlacement:
      {{- with .Values.hubconfig.tolerations }}
      tolerations:
      {{- range . }}
      - {{ if .Key }} key: {{ .Key }} {{- end }}
        {{ if .Operator }} operator: {{ .Operator }} {{- end }}
        {{ if .Value }} value: {{ .Value }} {{- end }}
        {{ if .Effect }} effect: {{ .Effect }} {{- end }}
        {{ if .TolerationSeconds }} tolerationSeconds: {{ .TolerationSeconds }} {{- end }}
        {{- end }}
      {{- end }}
      {{- with .Values.hubconfig.nodeSelector }}
      nodeSelector:
      {{- toYaml . | nindent 8 }}
      {{- end }}
```

**Under `proxyAgent:`, after `replicas`:**
```yaml
    # ACM addition: OpenShift service CA ConfigMap for service-proxy TLS verification. Not in upstream.
    additionalServiceCAConfigMap: openshift-service-ca.crt
    # ACM addition: pull secret for proxy-agent image on managed clusters. Not in upstream.
    imagePullSecrets:
    - "open-cluster-management-image-pull-credentials"
```

### Rule 7: ACM Addition to `user-service.yaml`

**Add annotation to metadata (upstream has no annotations):**
```yaml
  annotations:
    # ACM override: use OpenShift service-ca operator to auto-generate TLS cert instead
    # of upstream cert rotation (userServer.enabled=true). Upstream has no annotation.
    service.alpha.openshift.io/serving-cert-secret-name: cluster-proxy-user-serving-cert
```

### Rule 8: Label Changes in Deployments

The upstream uses `open-cluster-management.io/addon: cluster-proxy` as a label/selector.
The backplane adds ACM-specific labels on top while preserving the upstream label.

**In `manager-deployment.yaml`:**
- Change `component: cluster-proxy-manager` -> `component: cluster-proxy-addon-manager`
  (in metadata labels, matchLabels, and pod template labels)
- **Keep** `open-cluster-management.io/addon: cluster-proxy` in pod template labels (add it,
  as old backplane didn't have it but upstream does -- useful for addon framework identification)
- Add `ocm-antiaffinity-selector: cluster-proxy-addon-manager` to pod template labels
- Add `chart: cluster-proxy-addon-2.1.0` to metadata labels AND pod template labels
- **Keep** `chart: cluster-proxy-addon-2.1.0` in matchLabels (immutable, was there previously)

**In `user-deployment.yaml`:**
- **Keep** `open-cluster-management.io/addon: cluster-proxy` in pod template labels
- Add `ocm-antiaffinity-selector: cluster-proxy-addon-user` to pod template labels
- Add `chart: cluster-proxy-addon-2.1.0` to metadata labels AND pod template labels
- **Keep** `chart: cluster-proxy-addon-2.1.0` in matchLabels (immutable, was there previously)

**In `user-service.yaml`:**
- Keep `component: cluster-proxy-addon-user` and `chart: cluster-proxy-addon-2.1.0` in
  metadata labels
- Use `component: cluster-proxy-addon-user` + `chart: cluster-proxy-addon-2.1.0` as selector
  (NOT upstream's `open-cluster-management.io/addon` -- must match pod template labels that
  the backplane-only `user-route.yaml` also references)

### Rule 9: `clusterrole.yaml` -- Impersonation Conditional

Upstream wraps impersonation RBAC rules in `{{- if .Values.enableImpersonation }}`.
ACM always enables impersonation. `EnableImpersonation` IS in the Go `Values` struct,
set to `true` in `injectValuesOverrides()`.

**Preserve the upstream conditional** -- do not remove it. The Go value ensures it always
evaluates to true, but keeping the conditional means the template matches upstream structure
and the value can be changed from Go code if ever needed. Add comment:
```yaml
  # ACM: enableImpersonation set to true in renderer.go injectValuesOverrides. Conditional preserved from upstream.
  {{- if .Values.enableImpersonation }}
  ...
  {{- end }}
```

### Rule 10: NetworkPolicy Templates -- Toggle Path and PodSelector

The three networkpolicy templates use `{{ .Values.networkPolicies.enabled }}` in upstream.
Backplane uses `{{ .Values.global.networkPolicies.enabled }}` (same value from `NetworkPoliciesValue`
in the Go struct, set from `MCE spec.networkPolicies.enabled` in `injectValuesOverrides()`).

**Substitutions for all three NP files:**

| Upstream Pattern | Backplane Replacement | Rationale |
|---|---|---|
| `{{ .Values.networkPolicies.enabled }}` | `{{ .Values.global.networkPolicies.enabled }}` | NP toggle lives under `global.networkPolicies.enabled` in the backplane Values struct |
| `namespace: {{ .Release.Namespace }}` | *(remove)* | Backplane rendering engine sets namespace via `SetNamespace()` for `NetworkPolicy` kind resources |

**Additional override for `cluster-proxy-addon-manager-networkpolicy.yaml`:**

| Upstream | ACM Override | Comment to add |
|---|---|---|
| `component: cluster-proxy-manager` (podSelector) | `component: cluster-proxy-addon-manager` | Upstream and backplane use different component label values. Backplane pods have `cluster-proxy-addon-manager` (historical divergence; `matchLabels` are immutable). The NP podSelector must match actual pod labels or the policy selects no pods. |

The upstream NP files use **port-based peers** (empty `to:`/`from:` entries with explicit port
lists) for portability across Kubernetes vendors. Do NOT replace with OpenShift-specific
namespace selectors (`policy-group.network.openshift.io/ingress`, `openshift-dns`) -- the
upstream approach is intentionally vendor-neutral and should be preserved in the backplane copy.

### Rule 11: `user-deployment.yaml` -- Deprecated Field

Upstream uses the deprecated `serviceAccount:` field.
ACM uses `serviceAccountName:` (the current field).
Replace `serviceAccount: cluster-proxy` with `serviceAccountName: cluster-proxy`.

---

## Post-Sync Steps

After all templates and CRDs are updated, run in the backplane-operator repo:

```bash
# Regenerate rbac_gen.go from updated helm chart clusterrole.yaml
go generate ./...

# Regenerate config/rbac/role.yaml from all kubebuilder markers
make manifests

# Regenerate OLM bundle CSV
make bundle

# Run rendering tests
go test ./pkg/rendering/...

# Verify compilation
go build ./...
```

---

## Validation Checklist

After syncing, verify every item before opening a PR:

1. **No unknown `.Values.xxx` references**: Grep all template files for `.Values.` references.
   Every reference must be one of the known backplane paths or `enableServiceProxy` /
   `enableImpersonation`. Any unknown reference means a transformation rule is missing or
   upstream added a new value.

   Known valid paths:
   - `global.namespace`, `global.pullPolicy`, `global.pullSecret`,
     `global.imageOverrides.cluster_proxy`, `global.deployOnOCP`,
     `global.networkPolicies.enabled`
   - `hubconfig.replicaCount`, `hubconfig.nodeSelector`, `hubconfig.tolerations`,
     `hubconfig.proxyConfigs`, `hubconfig.ocpVersion`, `hubconfig.clusterIngressDomain`
   - `enableServiceProxy`, `enableKubeApiProxy`, `enableImpersonation`

2. **No new upstream template files**: Compare file list in `charts/cluster-proxy/templates/`
   against the File Inventory table. Any new file requires a new transformation rule. STOP
   and flag for review before proceeding.

3. **No removed upstream template files**: Any expected file missing from upstream means
   this skill document needs updating.

4. **CRD is verbatim copy**: `diff` the backplane CRD against the upstream CRD -- they must
   be byte-for-byte identical.

5. **Every ACM override has a comment**: Every place where the output diverges from upstream
   must have a `# ACM override:` or `# ACM addition:` comment explaining the rationale.

6. **Backplane-only files untouched**: `anp-route.yaml`, `anp-service.yaml`, and
   `user-route.yaml` must not be modified.

7. **RBAC regeneration succeeds**: `go generate ./...` and `make manifests` complete without
   errors.

8. **Rendering tests pass**: `go test ./pkg/rendering/...` passes.

9. **No `.Values.enableServiceProxy` reference in user-deployment or user-service without
   the upstream conditional guard**: These files should retain the `{{- if .Values.enableServiceProxy }}`
   wrapper from upstream (ACM sets `enableServiceProxy=true` so the content always renders,
   but the conditional must remain for structural alignment with upstream).

---

## Open Items

These are tracked issues that need investigation separately from the routine sync:

| Item | Detail |
|---|---|
| **ManagedProxyServiceResolver CRD** | Deprecated and removed upstream (commit 3eb1cef7, 2026-03-16). Still shipped in backplane across 6 files: CRD YAML, `rbac.go`, `rbac_gen.go`, `clusterrole.yaml`, `config/rbac/role.yaml`, OLM bundle CSV. Need to confirm no downstream ACM consumer creates `ManagedProxyServiceResolver` CRs before removing. |
| **`enableKubeApiProxy=false` rationale** | ACM disables kube-api proxy because ACM accesses managed cluster kube-apiserver through the service proxy (user-server Route, `enableServiceProxy=true`) rather than the kube-api proxy (ExternalName Service on managed clusters). See ACM docs: `cluster_proxy_addon_use.adoc` and `cluster_proxy_addon_config.adoc`. Upstream default is `true`. Commit bc36de88, Jan 2023. Status: **RESOLVED** |
| **TLS profile ConfigMap** | No gap. The `ocm-tls-profile` ConfigMap is created in `mce.Spec.TargetNamespace` by `ensureClusterManager()` (not by cluster-proxy-addon itself). All cluster-proxy pods run in the same `mce.Spec.TargetNamespace` (default: `multicluster-engine`), so `POD_NAMESPACE` matches. Note: cluster-proxy-addon consumes this ConfigMap but does not create it -- it depends on the cluster-manager component to create it. Status: **RESOLVED** |

---

## Checklist

### Step 1: Prepare repos

Ensure both repos are available:

```bash
# Update stolostron/cluster-proxy to latest
cd <cluster-proxy-path>
git checkout main && git pull origin main

# Create/update backplane-operator worktree on a working branch
# Use sfa-workspace-clone skill if needed
```

### Step 2: Check for new or removed upstream template files

List files in `<cluster-proxy>/charts/cluster-proxy/templates/`:

```bash
ls <cluster-proxy>/charts/cluster-proxy/templates/
```

Compare against the File Inventory table in this document. Note that the three
`*-networkpolicy.yaml` files are expected upstream files -- they are in the
NetworkPolicy Templates table, not the Upstream Files Skipped table.

**If any new file exists or an expected file is missing: STOP. Do not proceed. Update the
File Inventory and transformation rules in this skill first.**

### Step 3: Copy CRD verbatim

```bash
cp <cluster-proxy>/hack/crd/bases/proxy.open-cluster-management.io_managedproxyconfigurations.yaml \
   <backplane>/pkg/templates/crds/cluster-proxy-addon/proxy.open-cluster-management.io_managedproxyconfigurations.yaml
```

Verify it is an exact copy with no modifications.

### Step 4: Process each template file

For each file in the File Inventory (Upstream -> Backplane rows only):

1. Read the upstream template
2. Read the current backplane template (to understand what was previously there)
3. Apply Rule 1 (global substitutions) first
4. Apply the file-specific rules from Rules 2-10
5. Write the result -- preserve upstream structure, clearly layer ACM additions on top
6. Every divergence from upstream must have a `# ACM override:` or `# ACM addition:` comment

### Step 5: Verify backplane-only files are untouched

```bash
git diff <backplane>/pkg/templates/charts/toggle/cluster-proxy-addon/templates/anp-route.yaml
git diff <backplane>/pkg/templates/charts/toggle/cluster-proxy-addon/templates/anp-service.yaml
git diff <backplane>/pkg/templates/charts/toggle/cluster-proxy-addon/templates/user-route.yaml
```

All should show no changes.

### Step 6: Run validation checklist

Work through each item in the Validation Checklist section above.

### Step 7: Run post-sync steps

```bash
cd <backplane>
go generate ./...
make manifests
make bundle
go test ./pkg/rendering/...
go build ./...
```

All must succeed before opening a PR.

### Step 8: Review and present diff

```bash
git diff pkg/templates/charts/toggle/cluster-proxy-addon/
git diff pkg/templates/crds/cluster-proxy-addon/
```

Present a summary of:
- Key upstream changes brought in (new RBAC rules, new args, new CRD fields, API version changes)
- ACM overrides applied
- Any items requiring manual review or investigation
- Status of Open Items

---

## Lessons Learned (from first sync execution, July 2026)

### 1. Helm evaluates template syntax in YAML comments

Helm's template engine evaluates `{{ }}` blocks even inside YAML `#` comments. Any comment
containing `{{ .Values.xxx }}` or `{{ include "..." }}` will cause a render error. When writing
comments that document what upstream uses, do NOT use `{{ }}` -- write plain English instead.

**Wrong:** `# ACM override: upstream uses {{ .Values.replicas }}`
**Correct:** `# ACM override: upstream uses <replicas> value`

Similarly, bare `.Values.xxx` references in comment lines (without `{{ }}`) are also evaluated.
Use angle brackets or plain text: `# upstream uses .Values.replicas` will fail;
use `# upstream uses the replicas value` instead.

### 2. Go struct fields required for template conditionals

Any `{{- if .Values.xxx }}` conditional preserved from upstream requires the corresponding
field to exist in the Go `Values` struct in `pkg/rendering/renderer.go`. If the field is
missing, the engine will panic with `missingkey=error`.

For this sync, `EnableServiceProxy bool` was required (used in `user-deployment.yaml` and
`user-service.yaml` conditionals). Set its ACM default in `injectValuesOverrides()`.

### 3. ACM-specific labels must be preserved and cross-checked

The backplane chart uses `chart: cluster-proxy-addon-2.1.0` labels on pod templates that
upstream does not have. These labels are used as selectors in the backplane-only Service
and Route resources (`user-service.yaml`, `user-route.yaml`, `anp-service.yaml`). When
syncing deployment templates, always verify:

- What labels are on the pod template
- What selectors are on Services/Routes that target those pods
- That they match

The `open-cluster-management.io/addon: cluster-proxy` upstream label should be ADDED to
ACM pod templates (option A) -- keep both the upstream label and the ACM-specific labels.

### 4. Do not remove ACM additions without investigation

The `signer-ca` volume in `user-deployment.yaml` was added in a 2022 security fix and has
no volumeMount. It may look like dead code but removing it without understanding the original
intent is risky. Flag such items as pending investigation rather than removing them.

Similarly, do not remove RBAC rules for deprecated upstream resources (like
`managedproxyserviceresolvers`) until confirmed no downstream consumers still use them.

### 5. Service port names must match Route targetPort references

The backplane-only `user-route.yaml` references `targetPort: user-port`. The upstream
`user-service.yaml` uses port name `https`. When syncing `user-service.yaml`, override
the port name from upstream's `https` to `user-port` to match what `user-route.yaml` expects.

**Wrong (upstream):** `name: https`
**Correct (ACM):** `name: user-port`

Always check backplane-only Route files for `targetPort` references when syncing Services.

### 6. Verify env vars are actually consumed by the binary before adding them

Before adding an env var as an ACM addition, check whether the binary actually reads it.
The `POD_NAME` env var was added as an ACM addition to the manager container but the
`/manager` binary (cluster-proxy addon-manager) does not read `POD_NAME` -- only
`POD_NAMESPACE`. Adding unused env vars creates unnecessary divergence from upstream.

To verify: search the upstream binary's source code for `os.Getenv("ENV_VAR_NAME")` or
any reference to the env var name as a string constant.

### 7. Deployment matchLabels are immutable -- never change or remove them

Kubernetes Deployment `spec.selector.matchLabels` are **immutable** after creation. Any change
to matchLabels (including removing a label) will cause the server-side apply to fail with an
error on existing clusters. When syncing, always check what labels the existing deployed
Deployment selector has and preserve them exactly, even if upstream does not use them.

The backplane deployments use `chart: cluster-proxy-addon-2.1.0` in their matchLabels.
Upstream does not have this label. It must be kept in ACM matchLabels permanently, or it would
require deleting and recreating the Deployments (causing downtime) during upgrade.
