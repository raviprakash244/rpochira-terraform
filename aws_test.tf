# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}

# Define a vpc
#resource "aws_vpc" "${var.vpc_name}" {
#  cidr_block = "${var.vpc_cidr_block}"
#  tags = {
#    Name = "${var.vpc_name}"
#  }
#}


resource "aws_rds_cluster" "postgresql" {
  cluster_identifier      = "aurora-cluster-demo"
  engine                  = "aurora-postgresql"
  availability_zones      = [ "us-east-1a" ]
  database_name           = "mydb"
  master_username         = "rpochira"
  master_password         = "rpochira"
  backup_retention_period = 5
  preferred_backup_window = "07:00-09:00"
  skip_final_snapshot     = "true"
}




## Testing 
