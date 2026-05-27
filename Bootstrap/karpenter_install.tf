

# =========================
# Karpenter Namespace
# =========================

resource "kubernetes_namespace_v1" "karpenter" {
  metadata {
    name = var.karpenter_namespace
  }
}

# =========================
# Karpenter Helm Release
# =========================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  create_namespace = false
  wait             = true
  cleanup_on_fail  = true
  timeout          = 600

  set = [
    {
      name  = "settings.clusterName"
      value = local.cluster_name
    },

    {
      name  = "settings.interruptionQueue"
      value = local.karpenter_queue_name
    },

    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = local.karpenter_controller_role_arn
    },

    {
      name  = "controller.resources.requests.cpu"
      value = "1"
    },

    {
      name  = "controller.resources.requests.memory"
      value = "1Gi"
    },

    {
      name  = "controller.resources.limits.cpu"
      value = "1"
    },

    {
      name  = "controller.resources.limits.memory"
      value = "1Gi"
    },

    # Pin Karpenter pods to the existing managed node group
    {
      name  = "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key"
      value = "eks.amazonaws.com/nodegroup"
    },

    {
      name  = "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator"
      value = "In"
    },

    {
      name  = "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]"
      value = local.node_group_name
    }
  ]

  depends_on = [
    kubernetes_namespace_v1.karpenter,
    helm_release.karpenter_crds
  ]
}

# =========================
# Karpenter CRDs (installed separately for lifecycle safety)
# =========================
resource "helm_release" "karpenter_crds" {
  name             = "karpenter-crd"
  namespace        = var.karpenter_namespace
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_version
  create_namespace = false
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  depends_on = [
    kubernetes_namespace_v1.karpenter,
    helm_release.alb
  ]
}
