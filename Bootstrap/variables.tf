variable "region" {
  description = "The AWS region"
  type        = string
  default     = "ap-south-1"
}
variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  default     = "1.11.0"
}

variable "karpenter_namespace" {
  description = "namespace for karpenter"
  default     = "karpenter"
}