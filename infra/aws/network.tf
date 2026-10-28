resource "aws_security_group" "fleet" {
  name   = "ec2-fleet"
  vpc_id = data.aws_vpc.default.id

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
