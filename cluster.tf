# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}


module aws_aurora_db {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster1"

}



module aws_aurora_db {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster2"

}


module aws_aurora_db {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster3"

}

