terraform {
  backend "remote" {
    hostname = "app.terraform.io"
    organization = "rpochira"
    workspaces {
      name = "rpochira"
    }
  }
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
}

resource "aws_network_interface" "eni" {
  for_each = toset(local.subnet_ids) 

  subnet_id       = each.value  
  security_groups = ["sg-057749862a8753300"]

  tags = {
    Name = "eni-instance-${each.key + 1}"
  }
}


resource "aws_launch_template" "example" {
  for_each      = toset(local.subnet_ids) 
  name          = "couchbase-data-launch-template-${each.value}"
  image_id      = "ami-030c239b5d3296394"  
  instance_type = "t2.micro"                
  key_name      = "terminal"                

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = ["sg-057749862a8753300"]
    network_interface_id        = aws_network_interface.eni[each.key].id  
    device_index                = 0
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
  desired_capacity     = 3
  max_size             = 3
  min_size             = 3
  vpc_zone_identifier  = local.subnet_ids  

  launch_template {
    id      = aws_launch_template.example[local.subnet_ids[0]].id  
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
  autoscaling_group_name = aws_autoscaling_group.couchbase_data.name
  name                 = "example-lifecycle-hook"
  lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result       = "CONTINUE"
  heartbeat_timeout    = 120

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn
}

output "subnet_ids" {
  description = "The list of subnet IDs"
  value       = [for subnet in data.aws_subnet.subnets : subnet.id]
}
