data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = "terraform-s3-state-007"
    key    = "Infra/terraform.tfstate" #  same key as defined in Infra/backend.tf
    region = "ap-south-1"
  }
}

locals {
  vpc_id = data.terraform_remote_state.infra.outputs.vpc_id

  cluster_name     = data.terraform_remote_state.infra.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.infra.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.infra.outputs.cluster_ca

  alb_controller_role_arn       = data.terraform_remote_state.infra.outputs.alb_controller_role_arn

  karpenter_controller_role_arn = data.terraform_remote_state.infra.outputs.karpenter_controller_role_arn
  karpenter_queue_name          = data.terraform_remote_state.infra.outputs.karpenter_sqs_queue_name

  node_group_name = data.terraform_remote_state.infra.outputs.node_group_name
}