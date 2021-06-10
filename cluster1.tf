# Setup our aws provider

module cluster1 {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster1"

}

