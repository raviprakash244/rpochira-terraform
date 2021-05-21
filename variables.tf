
variable "vpc_region" {
  description = "Region in which VPC needs to be created"
}

variable "availability_zone" {
  description = "availability zone used. , based on region"
}

variable "vpc_name" {
  description = "VPC for building demos"
}


variable "vpc_cidr_block" {
  description = "Uber IP addressing for demo Network"
}
