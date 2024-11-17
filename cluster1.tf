terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "rpochira"
    workspaces {
      name = "rpochira"
    }
  }
}

# provider "aws" {
#   region = "us-east-1"
# }

# Variables for reusability (replace these values with your actual IDs)
variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
  default = "vpc-07208b1bbba41ce40"
}

variable "instance_count" {
  type    = number
  default = 3
}

variable "ami_id" {
  type    = string
  default = "ami-030c239b5d3296394"
}

variable "security_group" {
  type    = string
  default = "sg-057749862a8753300"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "subnet_name_list" {
  type    = list(string)
  default = ["private-subnet-1", "private-subnet-2", "private-subnet-3"]
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

data "aws_subnet" "subnets" { 
  for_each = toset(var.subnet_name_list)
  filter { 
    name   = "tag:Name"
    values = ["*${each.value}*"]
  }
}


locals {
  all_subnet_ids = [for subnet in data.aws_subnet.subnets : subnet.id]
  subnet_index   = [for i in range(var.instance_count) : i % length(local.all_subnet_ids)]
}


# EC2 Interface Endpoint
resource "aws_vpc_endpoint" "ec2_endpoint" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.us-east-1.ec2"
  vpc_endpoint_type = "Interface"
  subnet_ids = local.all_subnet_ids
  security_group_ids = [var.security_group]

  tags = {
    Name = "ec2-endpoint"
  }
}

# Autoscaling Interface Endpoint
resource "aws_vpc_endpoint" "autoscaling_endpoint" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.us-east-1.autoscaling"
  vpc_endpoint_type = "Interface"

  subnet_ids = local.all_subnet_ids

  security_group_ids = [var.security_group]

  tags = {
    Name = "autoscaling-endpoint"
  }
}

resource "aws_launch_template" "couchbase_data" {
  name          = "couchbase-data-launch-template"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = "terminal"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.security_group]
  }

  user_data = base64encode(<<EOF
#!/bin/bash
yum install -y aws-cli
INSTANCE_ID=$$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION="us-east-1"  # Correct region identifier
TAG_NAME="data-$${INSTANCE_ID}"
aws ec2 create-tags \
  --resources "$$INSTANCE_ID" \
  --tags Key=UniqueName,Value="$$TAG_NAME" \
  --region "$$REGION" >> /tmp/userdata.log 2>&1
EOF
  )
}

resource "aws_autoscaling_group" "couchbase_data" {
  desired_capacity    = var.instance_count
  max_size            = var.instance_count
  min_size            = var.instance_count
  vpc_zone_identifier = local.all_subnet_ids

  launch_template {
    id      = aws_launch_template.couchbase_data.id 
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "asg-cb-data"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
    }
  }

  health_check_type         = "EC2"
  health_check_grace_period = 60
}

resource "aws_network_interface" "data_eni" {
  count             = var.instance_count
  subnet_id         = local.all_subnet_ids[local.subnet_index[count.index]]
  security_groups = [var.security_group]
  tags = {
    Subnet               = local.all_subnet_ids[local.subnet_index[count.index]]
    UniqueTag            = "data_${count.index}"
    AutoscaleGroup       = aws_autoscaling_group.couchbase_data.name
  }
}

resource "aws_iam_role" "example_lifecycle_role" {
  name = "example-lifecycle-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "autoscaling.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "example_lifecycle_policy" {
  role = aws_iam_role.example_lifecycle_role.name
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:us-east-1:911167901101:asg_launch"
    }
  ]
}
EOF
}

resource "aws_autoscaling_lifecycle_hook" "example_hook" {
  autoscaling_group_name  = aws_autoscaling_group.couchbase_data.name  
  name                   = "asg-lifecyclehook-${aws_autoscaling_group.couchbase_data.name}"
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 120

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn
}


output "enis" {
  description = "The list of subnet IDs"
  value       = aws_network_interface.data_eni
}
