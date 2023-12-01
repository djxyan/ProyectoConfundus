terraform {
  backend "s3" {
    bucket = "terraform-accio"
    key    = "infra.tfstate"
    region = "us-east-1"
  }
}
