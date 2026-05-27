# =========================
# NodePool 1: Spot ARM64
# Weight 100 — tried first, cheapest
# =========================
resource "kubectl_manifest" "karpenter_node_pool_spot_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: spot-arm64
    spec:
      template:
        metadata:
          labels:
            # -----------------------------------------------
            # These labels land on the EC2 node.
            # Your pod affinity rules match against these.
            # -----------------------------------------------
            node-pool: spot-arm64
            capacity-type: spot
            arch: arm64
            workload-class: standard
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r"]
              # c6g, c7g, c8g — compute optimized Graviton
              # m6g, m7g, m8g — general purpose Graviton
              # r6g, r7g, r8g — memory optimized Graviton
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["5"]             # Graviton2+ only (gen 6,7,8)
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          expireAfter: 168h             # 7 days — shorter for spot nodes


      limits:
        cpu: 500
        memory: 2000Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 2m
      weight: 100
  YAML

  depends_on = [helm_release.karpenter]
}

# =========================
# NodePool 2: Spot AMD64
# Weight 75 — second choice
# =========================
resource "kubectl_manifest" "karpenter_node_pool_spot_amd64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: spot-amd64
    spec:
      template:
        metadata:
          labels:
            node-pool: spot-amd64
            capacity-type: spot
            arch: amd64
            workload-class: standard
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["3"]             # c4+, m4+, r4+ and newer
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          expireAfter: 168h
          
      limits:
        cpu: 500
        memory: 2000Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 2m
      weight: 75
  YAML

  depends_on = [helm_release.karpenter]
}

# =========================
# NodePool 3: On-Demand ARM64
# Weight 50 — is it worth it? See explanation below.
# =========================
resource "kubectl_manifest" "karpenter_node_pool_ondemand_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: ondemand-arm64
    spec:
      template:
        metadata:
          labels:
            node-pool: ondemand-arm64
            capacity-type: on-demand
            arch: arm64
            # -----------------------------------------------
            # workload-class: stable — different from "critical"
            # on-demand x86. Use this for workloads that:
            #  - need stability (no spot interruption)
            #  - are ARM-compatible
            #  - don't need the absolute max on-demand x86 SLA
            # Example: background workers, async processors
            # that have multi-arch images but can't tolerate
            # spot interruptions mid-job.
            # -----------------------------------------------
            workload-class: stable
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["m", "r"]        # m7g, r7g — stable general + memory
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["5"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          expireAfter: 720h
          
      limits:
        cpu: 200
        memory: 800Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 10m           # more conservative than spot pools
      weight: 50
  YAML

  depends_on = [helm_release.karpenter]
}

# =========================
# NodePool 4: On-Demand AMD64
# Weight 10 — absolute last resort / critical only
# =========================
resource "kubectl_manifest" "karpenter_node_pool_ondemand_amd64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: ondemand-amd64
    spec:
      template:
        metadata:
          labels:
            node-pool: ondemand-amd64
            capacity-type: on-demand
            arch: amd64
            workload-class: critical    # ← only label on on-demand x86
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["m", "r"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["4"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          expireAfter: 720h
          
      limits:
        cpu: 200
        memory: 800Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized  # use podDisruptionBudget and proper handling in the code 
        consolidateAfter: 20m
      weight: 10
  YAML

  depends_on = [helm_release.karpenter]
}