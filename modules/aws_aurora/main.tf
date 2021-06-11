# Setup our aws provider
resource "aws_rds_cluster" "aws_aurora" {
  cluster_identifier      = var.cluster_name
  engine                  = "aurora-postgresql"
  availability_zones      = [ "us-east-1a" ]
  database_name           = "mydb"
  master_username         = "rpochira"
  master_password         = "rpochira"
  backup_retention_period = 5
  preferred_backup_window = "07:00-09:00"
  skip_final_snapshot     = "true"
  deletion_protection     = "true"
}

