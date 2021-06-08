# Setup our aws provider

provider "aws" {
  alias  = "aurora-cluster-demo2"
  region = "${var.vpc_region}"
}


resource "aws_rds_cluster" "aurora-cluster-demo2" {
  cluster_identifier      = "aurora-cluster-demo2"
  engine                  = "aurora-postgresql"
  availability_zones      = [ "us-east-1a" ]
  database_name           = "mydb"
  master_username         = "rpochira"
  master_password         = "rpochira"
  backup_retention_period = 5
  preferred_backup_window = "07:00-09:00"
  skip_final_snapshot     = "true"
}
