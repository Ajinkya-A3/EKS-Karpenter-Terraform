terraform {
  backend "s3" {
    bucket       = "terraform-s3-state-007"
    key          = "Bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}