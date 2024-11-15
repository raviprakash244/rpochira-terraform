# Setup AWS provider with remote backend
terraform {
  backend "remote" {
    hostname = "app.terraform.io"
    organization = "rpochira"
    workspaces {
      name = "rpochira"
    }
  }
}

# Define the subnet names list as a variable
variable "subnet_name_list" {
  type    = list(string)
  default = ["private-subnet-1", "private-subnet-2", "private-subnet-3"]
}

resource "aws_network_interface" "eni" {
  count         = length(var.subnet_name_list)
  subnet_id     = data.aws_subnet.subnets[count.index].id
  security_groups = ["sg-057749862a8753300"] # Replace with appropriate security group ID
  description   = "ENI for Couchbase"
}

locals {
  eni_ids = [for i in range(length(data.aws_subnet.subnets)) : aws_network_interface.eni[i].id]
}

# Launch Template for EC2 instances
resource "aws_launch_template" "example" {
  name          = "couchbase-data-launch-template"
  image_id      = "ami-030c239b5d3296394"  # Replace with your AMI ID
  instance_type = "t2.micro"                # Replace with your instance type

  key_name      = "terminal"               # Replace with your SSH key

  network_interfaces {
    associate_public_ip_address = false
    network_interface_id = local.eni_ids[count.index]
    device_index         = 0
  }

  user_data = base64encode(<<EOF
#!/bin/bash

yum install -y aws-cli
INSTANCE_ID=$$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION="us-east-1"  # Correct region identifier
TAG_NAME="data-$${INSTANCE_ID}"

# Add tags to the instance
aws ec2 create-tags \
  --resources "$$INSTANCE_ID" \
  --tags Key=UniqueName,Value="$$TAG_NAME" \
  --region "$$REGION" >> /tmp/userdata.log 2>&1
EOF
  )
}

# Retrieve subnets with the specified tags
data "aws_subnet" "subnets" { 
  count = 3
  filter { 
    name   = "tag:Name"
    values = ["*${var.subnet_name_list[(count.index % 3)]}*"]
  }
}

# Local variable to hold subnet IDs
locals {
  subnet_ids = [for subnet in data.aws_subnet.subnets : subnet.id]
}

# Auto Scaling Group resource
resource "aws_autoscaling_group" "couchbase_data" {
  desired_capacity     = 1
  max_size             = 1
  min_size             = 1
  vpc_zone_identifier  = local.subnet_ids

  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "asg-example-instance"
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

# IAM Role for Auto Scaling Lifecycle Hook to access SNS
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

# IAM Role Policy to allow SNS publishing
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

# Auto Scaling Lifecycle Hook to capture instance launch event
resource "aws_autoscaling_lifecycle_hook" "example_hook" {
  autoscaling_group_name = aws_autoscaling_group.couchbase_data.name
  name                 = "example-lifecycle-hook"
  lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result       = "CONTINUE"
  heartbeat_timeout    = 120

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn
}

# Output to display subnet IDs
output "subnet_ids" {
  description = "The list of subnet IDs"
  value       = [for subnet in data.aws_subnet.subnets : subnet.id]
}

output "launch_template_version" {
  value = aws_launch_template.example.latest_version
}