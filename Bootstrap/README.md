# Karpenter NodePool Setup — Reference Guide

## Overview

This cluster uses **4 NodePools** arranged in a cost-priority fallback chain.
Karpenter automatically picks the cheapest available capacity for every pending pod.

```
spot-arm64 (weight: 100)  →  spot-amd64 (weight: 75)  →  ondemand-arm64 (weight: 50)  →  ondemand-amd64 (weight: 10)
   cheapest                      second                        third                           last resort
   ~70% off OD x86               ~60% off OD x86               ~20% off OD x86                 full price
```

Karpenter tries the highest-weight pool first. If that pool has no available spot capacity
in your AZs, it automatically falls back to the next pool.

---

## NodePool Reference

| NodePool | Arch | Capacity | Weight | Label: `node-pool` | Label: `workload-class` | Label: `capacity-type` |
|---|---|---|---|---|---|---|
| `spot-arm64` | arm64 | spot | 100 | `spot-arm64` | `standard` | `spot` |
| `spot-amd64` | amd64 | spot | 75 | `spot-amd64` | `standard` | `spot` |
| `ondemand-arm64` | arm64 | on-demand | 50 | `ondemand-arm64` | `stable` | `on-demand` |
| `ondemand-amd64` | amd64 | on-demand | 10 | `ondemand-amd64` | `critical` | `on-demand` |

> **The labels in the middle 3 columns are stamped onto every EC2 node provisioned by that pool.**
> Your pod manifests use these labels in `nodeAffinity` to control placement.

---

## Quick-Start: Which affinity do I use?

| My workload is... | Use this pattern |
|---|---|
| Stateless API / web service with multi-arch image | [Fallback Chain](#pattern-1-full-fallback-chain-recommended-for-stateless-apis) |
| x86-only binary (legacy app, old native lib) | [Force x86 Spot](#pattern-2-force-x86-only-spot--on-demand-fallback) |
| Database / stateful / cannot be interrupted | [On-Demand Only](#pattern-3-critical-workload-on-demand-only) |
| Batch job / queue worker | [Spot Only](#pattern-4-batch-job--spot-only) |
| Long-running worker, multi-arch, no interruption | [On-Demand ARM](#pattern-5-stable-worker-on-demand-arm) |

---

## Pattern 1: Full Fallback Chain (recommended for stateless APIs)

Rides the full chain: spot ARM → spot x86 → on-demand ARM → on-demand x86.
Use this for any stateless service with a **multi-arch Docker image**.

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-pool
              operator: In
              values: ["spot-arm64"]
      - weight: 75
        preference:
          matchExpressions:
            - key: node-pool
              operator: In
              values: ["spot-amd64"]
      - weight: 50
        preference:
          matchExpressions:
            - key: node-pool
              operator: In
              values: ["ondemand-arm64"]
    # ondemand-amd64 has no preference — it's the implicit last resort
```

Full deployment example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: production
spec:
  replicas: 4
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
    spec:
      # Spread pods across zones for spot resilience
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: api-service
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: node-pool
                    operator: In
                    values: ["spot-arm64"]
            - weight: 75
              preference:
                matchExpressions:
                  - key: node-pool
                    operator: In
                    values: ["spot-amd64"]
            - weight: 50
              preference:
                matchExpressions:
                  - key: node-pool
                    operator: In
                    values: ["ondemand-arm64"]
      terminationGracePeriodSeconds: 60
      containers:
        - name: api
          image: your-registry/api-service:latest   # must be multi-arch
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-service-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: api-service
```

---

## Pattern 2: Force x86 Only (spot → on-demand fallback)

Use when your image is **x86-only** (legacy binary, old native library, no arm64 build).
Hard-blocks ARM via a `required` rule. Prefers spot-amd64, falls back to on-demand-amd64.

```yaml
affinity:
  nodeAffinity:
    # HARD rule — pod will never land on arm64
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/arch    # built-in k8s label
              operator: In
              values: ["amd64"]
    # Soft rule — try spot first
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-pool
              operator: In
              values: ["spot-amd64"]
```

---

## Pattern 3: Critical Workload — On-Demand Only

Use for **databases, payment services, auth services** — anything that cannot be
interrupted by a spot reclaim. The `workload-class: critical` label exists **only**
on the `ondemand-amd64` pool, so this hard-blocks all spot nodes automatically.

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: workload-class
              operator: In
              values: ["critical"]      # only ondemand-amd64 has this label
```

Full StatefulSet example:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: production
spec:
  replicas: 2
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: workload-class
                    operator: In
                    values: ["critical"]
        # Never put 2 replicas on the same node
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: postgres
              topologyKey: kubernetes.io/hostname
      containers:
        - name: postgres
          image: postgres:16            # official image is multi-arch
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postgres-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: postgres
```

---

## Pattern 4: Batch Job — Spot Only

Use for **queue workers, data processing, CI jobs** — workloads that can be retried
if interrupted. Hard-require spot, prefer ARM for the extra savings.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-processor
spec:
  parallelism: 10
  completions: 100
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      # Long grace period — checkpoint your work before the pod dies
      terminationGracePeriodSeconds: 120
      affinity:
        nodeAffinity:
          # Hard require spot — never waste on-demand budget on batch
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: capacity-type
                    operator: In
                    values: ["spot"]
          # Prefer ARM for extra savings
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: arch
                    operator: In
                    values: ["arm64"]
      containers:
        - name: processor
          image: your-registry/processor:latest    # multi-arch recommended
          resources:
            requests:
              cpu: "2"
              memory: "4Gi"
```

---

## Pattern 5: Stable Worker — On-Demand ARM

Use for **long-running async workers, ML inference, queue consumers** that have
multi-arch images, cannot tolerate spot interruptions, but don't need the
absolute criticality of `ondemand-amd64`. Saves ~20% vs on-demand x86.

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: workload-class
              operator: In
              values: ["stable"]        # only ondemand-arm64 has this label
```

---

## Node Labels Reference

Every node provisioned by Karpenter carries these labels.
Use them in your pod `nodeAffinity` or `nodeSelector`.

### Custom labels (set in NodePool `template.metadata.labels`)

| Label | Values | Set by NodePool |
|---|---|---|
| `node-pool` | `spot-arm64` / `spot-amd64` / `ondemand-arm64` / `ondemand-amd64` | All pools |
| `capacity-type` | `spot` / `on-demand` | All pools |
| `arch` | `arm64` / `amd64` | All pools |
| `workload-class` | `standard` / `stable` / `critical` | All pools |

### Built-in labels (set automatically by Kubernetes/AWS)

| Label | Example Value | Use case |
|---|---|---|
| `kubernetes.io/arch` | `arm64` / `amd64` | Hard-block ARM for x86-only images |
| `karpenter.sh/capacity-type` | `spot` / `on-demand` | Karpenter's own capacity label |
| `topology.kubernetes.io/zone` | `ap-south-1a` | Zone spreading |
| `kubernetes.io/hostname` | `ip-10-0-1-5.ec2.internal` | Pod anti-affinity per node |
| `node.kubernetes.io/instance-type` | `m7g.xlarge` | Pin to specific instance type |

---

## `required` vs `preferred` — When to Use Which

```
requiredDuringSchedulingIgnoredDuringExecution
  = HARD rule. Pod stays Pending forever if no matching node exists.
  = Use for: "never on spot", "never on ARM", "only on-demand"

preferredDuringSchedulingIgnoredDuringExecution
  = SOFT rule. Karpenter tries its best, falls back if not available.
  = Use for: fallback chains, "prefer ARM over x86", "prefer spot"
```

**Rule of thumb:** use `required` to block something, use `preferred` to guide preference.
Never use `required` for the fallback chain — pods will get stuck Pending.

---

## Workload Compatibility: ARM vs x86

### Works on ARM (multi-arch image needed for your own code)

- Go applications (excellent ARM support)
- Node.js, Python, Ruby, PHP
- Java / Kotlin (JARs run anywhere)
- .NET 6+ (full ARM64 support)
- Rust (first-class ARM support)
- nginx, envoy, istio, linkerd
- Postgres, MySQL, Redis, RabbitMQ, Kafka
- Most official Docker Hub images

### x86 Only — cannot run on ARM

- x86-compiled binaries without cross-compile
- Legacy JNI native extensions compiled for x86
- Some ML inference libs (TensorRT, some CUDA ops)
- Old APM/monitoring agents (check your vendor's docs)
- Some proprietary vendor software

### How to check if an image supports ARM

```bash
# Check manifest for arm64 platform
docker manifest inspect postgres:16 | grep -A2 '"architecture"'

# Or use crane
crane manifest your-registry/app:latest | jq '.manifests[].platform'
```

### Building multi-arch images in CI (GitHub Actions)

```yaml
- name: Build and push multi-arch image
  uses: docker/build-push-action@v5
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: your-registry/your-app:latest
```

---

## EC2NodeClass — What It Controls

The `EC2NodeClass` is the AWS-specific blueprint. NodePool decides *when and what size*
to provision; EC2NodeClass decides *how* to build the instance.

| Field | What it does |
|---|---|
| `role` | IAM role attached to the EC2 node (needs EKS worker policies) |
| `amiSelectorTerms` | Which AMI to use. `al2023@latest` auto-picks arm64 or x86 AMI based on arch |
| `subnetSelectorTerms` | Finds your private subnets by tag — tag your subnets with `karpenter.sh/discovery: <cluster>` |
| `securityGroupSelectorTerms` | Finds your node SG by tag — same tag pattern |
| `blockDeviceMappings` | Root volume size, type (always use `gp3`), encryption |
| `userData` | Runs on boot — kubelet config, eviction thresholds, sysctl tuning |
| `tags` | Cost allocation tags on the EC2 instance |

> `al2023@latest` automatically selects the correct AMI for both arm64 and amd64 nodes.
> You do **not** need separate EC2NodeClasses per architecture.

---

## Spot Interruption Handling

Karpenter receives a **2-minute warning** before AWS reclaims a spot node.
It will cordon the node and reschedule pods automatically — but your pods must handle it:

1. Set `terminationGracePeriodSeconds` high enough to finish in-flight work
2. Add a `preStop` hook to drain connections
3. Always set a `PodDisruptionBudget` so Karpenter won't drain too many pods at once
4. For batch jobs: checkpoint your work so you can resume after rescheduling

```yaml
# Minimum viable spot-safe deployment config
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 1          # or maxUnavailable: 1
  selector:
    matchLabels:
      app: your-app
```

---

## Cost Saving Summary

| Strategy | Approximate Saving |
|---|---|
| Spot ARM64 vs On-Demand x86 | ~70–80% |
| Spot x86 vs On-Demand x86 | ~60–70% |
| On-Demand ARM64 vs On-Demand x86 | ~20% |
| Aggressive consolidation (`WhenEmptyOrUnderutilized`) | Eliminates idle node waste |
| Node expiry (`expireAfter: 168h` on spot) | Prevents stale/bloated nodes |

**Migration order for maximum savings:**
1. Move batch jobs and queue workers to spot first (safest, retry-friendly)
2. Build multi-arch images in CI for your stateless services
3. Move stateless APIs to the full fallback chain
4. Move stable workers to on-demand ARM
5. Keep only databases and truly critical services on on-demand x86