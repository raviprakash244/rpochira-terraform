terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "rpochira"
    workspaces {
      name = "rpochira"
    }
  }
}

variable "instance_count" {
  type    = number
  default = 6
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

data "aws_subnet" "subnets" { 
  for_each = toset(var.subnet_name_list)
  filter { 
    name   = "tag:Name"
    values = ["*${each.value}*"]
  }
}

locals {
  subnet_ids = [for subnet in data.aws_subnet.subnets : subnet.id]
  all_subnet_ids = [
    for i in range(var.instance_count) : local.subnet_ids[i % length(local.subnet_ids)]
  ]
}

resource "aws_network_interface" "data_eni" {
  for_each = toset(local.all_subnet_ids)
  subnet_id       = each.value  
  security_groups = [var.security_group]
  tags {
    Subnet               = "${each.value}"
    UniqueTag            = "data_${each.index}"
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
  vpc_zone_identifier = local.subnet_ids

  launch_template {
    id      = aws_launch_template.couchbase_data.id 
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "asg-cb-data-${each.value}"
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
  for_each = toset(local.subnet_ids)  # Iterate over subnets or ASGs

  autoscaling_group_name  = aws_autoscaling_group.couchbase_data.name  
  name                   = "asg-cbdata-lifecycle-hook"
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 120

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn
}


output "subnet_ids" {
  description = "The list of subnet IDs"
  value       = local.all_subnet_ids
}