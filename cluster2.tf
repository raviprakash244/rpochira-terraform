# Setup our aws provider

module cluster2 {
  source = "./modules/aws_aurora"

  cluster_name   = "cluster2"

}

