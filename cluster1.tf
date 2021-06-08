# Setup our aws provider

provider "aws" {
  region = "us-east-1"
}


resource "aws_rds_cluster" "aurora-cluster-demo2" {
  preferred_backup_window = "10:00-09:00"
}
