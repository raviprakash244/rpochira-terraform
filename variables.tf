variable "aws_access_key_id" {
  description = "AWS access key"
  default = ${aws_access_key_id}
}

variable "aws_secret_access_key" {
  description = "AWS secret access key"
  default = ${aws_secret_access_key}
}

variable "vpc_region" {
  description = "Region in which VPC needs to be created"
  default = "us-east-1a"
}

variable "availability_zone" {
  description = "availability zone used. , based on region"
  default = {
    us-east-1 = "us-east-1a"
    us-west-1 = "us-west-1a"
  }
}

variable "vpc_name" {
  description = "VPC for building demos"
  default = "vpc_database"
}


variable "vpc_cidr_block" {
  description = "Uber IP addressing for demo Network"
  default = "10.10.0.0/16"
}
