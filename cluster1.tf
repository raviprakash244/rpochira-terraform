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

data "aws_subnet" "subnets" { 
    filter { 
        name = "tag:Name"
        values = ["*${var.subnet_name_list[(count.index%3)]}*"]
    }
    count = 3
}
