resource "aws_security_group" "crm" {
  name        = "mini-crm-sg"
  description = "Security group for Mini CRM EC2"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name    = "mini-crm-sg"
    Project = "MiniCRM"
  }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.crm.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.crm.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}
