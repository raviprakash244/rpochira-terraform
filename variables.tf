
variable "vpc_region" {
  description = "Region in which VPC needs to be created"
  default = "us-east-1"
}


variable "vpc_name" {
  description = "VPC for building demos"
  default = "aws_vpc_tf1"
}


variable "vpc_cidr_block" {
  description = "Uber IP addressing for demo Network"
  default = "10.10.1.0/16"
}



  

