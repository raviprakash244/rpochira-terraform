# Setup our aws provider
resource "aws_rds_cluster" "aws_aurora" {
  preferred_backup_window = "08:00-09:00"
  skip_final_snapshot     = "true"
  deletion_protection     = "true"
}

