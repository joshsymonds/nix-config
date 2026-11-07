moved {
  from = aws_security_group.fleet
  to   = aws_security_group.fleet["us-west-2"]
}

resource "aws_security_group" "fleet" {
  for_each = toset(local.fleet_regions)
  region   = each.key

  name   = "ec2-fleet"
  vpc_id = data.aws_vpc.default[each.key].id

  ingress = []

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    fleet = "ec2-sg"
  }
}
