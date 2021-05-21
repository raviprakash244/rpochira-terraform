# Setup our aws provider

provider "aws" {
  access_key = "${var.aws_access_key_id}"
  secret_key = "${var.aws_secret_access_key}"
  region = "${var.vpc_region}"
}


# Define a vpc
resource "aws_vpc" "vpc_name" {
  cidr_block = "${var.vpc_cidr_block}"
  tags {
    Name = "${var.vpc_name}"
  }
}

