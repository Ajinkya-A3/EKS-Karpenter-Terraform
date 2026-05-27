resource "kubernetes_service_account_v1" "alb" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = local.alb_controller_role_arn
    }
  }


}

# Helm Install
resource "helm_release" "alb" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  # cleanup_on_fail ensures that if the Helm release installation fails, it will be automatically cleaned up, preventing orphaned resources and ensuring a clean state for subsequent attempts.
  cleanup_on_fail = true
  wait            = true
  timeout         = 600


  depends_on = [
    kubernetes_service_account_v1.alb
  ]

  set = [
    {
      name  = "clusterName"
      value = local.cluster_name
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.alb.metadata[0].name
    },
    {
      name  = "vpcId"
      value = local.vpc_id
    },
    {
      name  = "region"
      value = var.region
    }
  ]
}