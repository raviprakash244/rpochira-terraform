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



output "subnet_ids" {
  description = "The list of subnet IDs"
  value       = [for subnet in data.aws_subnet.subnets : subnet.id]
}