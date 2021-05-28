# Setup our aws provider

provider "aws" {
  region = "${var.vpc_region}"
}

# Define a vpc
resource "aws_vpc" "${var.vpc_name}" {
  cidr_block = "${var.vpc_cidr_block}"
  tags = {
    Name = "${var.vpc_name}"
  }
}

