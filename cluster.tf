# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}


module cluster1 {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster1"

}



module cluster2 {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster2"

}


module cluster3 {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster3"

}

