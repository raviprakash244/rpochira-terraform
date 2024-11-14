# Setup our aws provider
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
    default = ["subnet1", "subnet2", "subnet3", "subnet4", "subnet5", "subnet6"]
}

data "aws_subnet" "subnets" { 
    count = 3
    filter { 
        name   = "tag:Name"
        values = ["*${var.subnet_name_list[(count.index % 3)]}*"]
    }
}

resource "aws_launch_template" "example" {
  name          = "couchbase-data-launch-template"
  image_id      = "ami-030c239b5d3296394"  
  instance_type = "t2.micro"               

  key_name      = "terminal"            

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = ["sg-057749862a8753300"] 
  }

  # Specify additional configurations
  user_data = base64encode(<<EOF
#!/bin/bash

yum install -y aws-cli
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION="us-east1" 

TAG_NAME="data-${INSTANCE_ID}" 

# Add tags to the instance
aws ec2 create-tags \
  --resources "$INSTANCE_ID" \
  --tags Key=Name,Value="$TAG_NAME" \
  --region "$REGION"
EOF
  )
}


resource "aws_autoscaling_group" "couchbase_data" {
  desired_capacity     = 1                 
  max_size             = 1                 
  min_size             = 1                  
  vpc_zone_identifier  = data.aws_subnet.subnets.ids
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

  health_check_type         = "EC2"
  health_check_grace_period = 300

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
  name                   = "example-lifecycle-hook"
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"  
  default_result         = "CONTINUE"                            
  heartbeat_timeout      = 1800                                   

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn # IAM role for notification permissions
}



output "subnet_ids" {
  description = "The list of subnet IDs"
  value       = [for subnet in data.aws_subnet.subnets : subnet.id]
}