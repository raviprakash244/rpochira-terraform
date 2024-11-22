terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "rpochira"
    workspaces {
      name = "rpochira"
    }
  }
}

resource "random_pet" "asg_name" {
  length    = 2       
  separator = "-"     
}

locals {
  asg_name = "asg-${random_pet.asg_name.id}"
}

variable "availability_zones" {
  description = "List of Availability Zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"] 
}

# Create a VPC
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"  
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "my-vpc"
  }
}


resource "aws_subnet" "public_subnet_a" {
  vpc_id              = aws_vpc.my_vpc.id
  cidr_block          = "10.0.1.0/24"  
  availability_zone   = "us-east-1a"    

  map_public_ip_on_launch = true  

  tags = {
    Name = "PublicSubnet-A"
  }
}

resource "aws_subnet" "public_subnet_b" {
  vpc_id              = aws_vpc.my_vpc.id
  cidr_block          = "10.0.2.0/24"
  availability_zone   = "us-east-1b"    

  map_public_ip_on_launch = true 

  tags = {
    Name = "PublicSubnet-B"
  }
}

resource "aws_subnet" "public_subnet_c" {
  vpc_id              = aws_vpc.my_vpc.id
  cidr_block          = "10.0.3.0/24"
  availability_zone   = "us-east-1c"    

  map_public_ip_on_launch = true  

  tags = {
    Name = "PublicSubnet-C"
  }
}

resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "my-igw"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "PublicRouteTable"
  }
}

resource "aws_route_table_association" "rt_assoc_a" {
  subnet_id      = aws_subnet.public_subnet_a.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "rt_assoc_b" {
  subnet_id      = aws_subnet.public_subnet_b.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "rt_assoc_c" {
  subnet_id      = aws_subnet.public_subnet_c.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.my_vpc.id

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
  }

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
  }

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
  }

  tags = {
    Name = "EC2-SG"
  }
}

# Variables for reusability (replace these values with your actual IDs)
# variable "vpc_id" {
#   description = "The ID of the VPC"
#   type        = string
#   default = aws_vpc.main_vpc.id
# }

variable "instance_count" {
  type    = number
  default = 6
}

variable "ami_id" {
  type    = string
  default = "ami-030c239b5d3296394"
}

# variable "security_group" {
#   type    = string
#   default = aws_security_group.ec2_sg.id
# }

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

locals {
  subnet_ids = [
    aws_subnet.public_subnet_a.id,
    aws_subnet.public_subnet_b.id,
    aws_subnet.public_subnet_c.id
  ]
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

# data "aws_subnet" "subnets" { 
#   for_each = toset(data.aws_subnet.subnet_name_list)
#   filter { 
#     name   = "tag:Name"
#     values = ["*${each.value}*"]
#   }
# }

locals {
  all_subnet_ids = local.subnet_ids
  subnet_index   = [for i in range(var.instance_count) : i % length(local.all_subnet_ids)]
}

resource "aws_launch_template" "couchbase_data" {
  name          = "couchbase-data-launch-template"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = "terminal"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2_sg.id]
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
  name                = local.asg_name
  desired_capacity    = var.instance_count
  max_size            = var.instance_count
  min_size            = var.instance_count
  vpc_zone_identifier = local.all_subnet_ids
  # availability_zones = var.availability_zones

  launch_template {
    id      = aws_launch_template.couchbase_data.id 
    version = "$Latest"
  }

  

  tag {
      key                 = "Name"
      value               = "asg-cb-data"
      propagate_at_launch = true
    }

  tag {
      key                 = "Status"
      value               = "available"
      propagate_at_launch = true
    }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [tag]
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
    }
  }

  health_check_type         = "EC2"
  health_check_grace_period = 60

  depends_on = [null_resource.eni_delay]
}

resource "aws_network_interface" "data_eni" {
  count             = var.instance_count
  subnet_id         = local.all_subnet_ids[local.subnet_index[count.index]]
  security_groups = [aws_security_group.ec2_sg.id]
  tags = {
    Subnet               = local.all_subnet_ids[local.subnet_index[count.index]]
    UniqueTag            = "data_${count.index}"
    AutoscaleGroup       = local.asg_name
    NodeStatus           = "available"
  }

  lifecycle {
    ignore_changes = [tags]
  }

}

resource "null_resource" "eni_delay" {
  provisioner "local-exec" {
    command = "sleep 10" 
  }

  depends_on = [aws_network_interface.data_eni]
}

resource "aws_ebs_volume" "data_ebs" {
  for_each = toset(var.availability_zones) 

  availability_zone = each.key  
  size              = 8         
  type       = "gp2"     

  tags = { 
    AvailabilityZone = each.key
    AsgName  = local.asg_name
    Status   = "available"
  }

  lifecycle {
    ignore_changes = [tags]
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

resource "aws_autoscaling_lifecycle_hook" "data_launch_hook" {
  autoscaling_group_name  = aws_autoscaling_group.couchbase_data.name  
  name                   = "asg-lifecyclehook-${aws_autoscaling_group.couchbase_data.name}_launch"
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 1800

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn
}

resource "aws_autoscaling_lifecycle_hook" "data_termination_hook" {
  autoscaling_group_name  = aws_autoscaling_group.couchbase_data.name  
  name                   = "asg-lifecyclehook-${aws_autoscaling_group.couchbase_data.name}_termination"
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 1800

  notification_target_arn = "arn:aws:sns:us-east-1:911167901101:asg_launch"
  role_arn                = aws_iam_role.example_lifecycle_role.arn
}

output "enis" {
  description = "The list of subnet IDs"
  value       = aws_network_interface.data_eni
}
