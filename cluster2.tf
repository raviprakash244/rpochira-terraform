# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}


resource "aws_rds_cluster" "postgresql1" {
  cluster_identifier      = "aurora-cluster-demo1"
  engine                  = "aurora-postgresql"
  availability_zones      = [ "us-east-1a" ]
  database_name           = "mydb"
  master_username         = "rpochira"
  master_password         = "rpochira"
  backup_retention_period = 5
  preferred_backup_window = "07:00-09:00"
  skip_final_snapshot     = "true"
}
