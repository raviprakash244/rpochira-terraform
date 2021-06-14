# Setup our aws provider
terraform {
  backend "remote" {
      hostname = "app.terraform.io"
      organization = "rpochira"
      workspaces {
        name = "rpochira"
      }
  }
}

resource "aws_rds_cluster" "aurora-cluster-demo" {
  cluster_identifier      = "aurora-cluster-demo"
  engine                  = "aurora-postgresql"
  availability_zones      = [ "us-east-1a" ]
  database_name           = "mydb"
  master_username         = "rpochira"
  master_password         = "rpochira"
  backup_retention_period = 5
  preferred_backup_window = "08:00-09:00"
  db_subnet_group_name    = "default"

}
