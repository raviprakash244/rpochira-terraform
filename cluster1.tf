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
    default = ["subnet1", "subnet2", "subnet3"]
}

data "aws_subnet" "subnets" { 
    count = 3
    filter { 
        name   = "tag:Name"
        values = ["*${var.subnet_name_list[(count.index % 3)]}*"]
    }
}