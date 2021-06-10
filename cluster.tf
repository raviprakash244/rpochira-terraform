# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}


module ${var.cluster_name} {
  source = "./modules/aws_aurora"

  cluster_name   = var.cluster_name

}

