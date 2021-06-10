# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}


module "rds_cluster1" {
  source = "./modules/aws_aurora"

  cluster_name   = "testcluster2"

}

