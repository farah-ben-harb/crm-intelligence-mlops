data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "crm" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = "t3.small"

  subnet_id                   = "subnet-07f4eba661f58a420"
  associate_public_ip_address = true

  vpc_security_group_ids = [aws_security_group.crm.id]
  iam_instance_profile   = aws_iam_instance_profile.crm.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y docker
    systemctl enable --now docker
    systemctl enable --now amazon-ssm-agent
  EOF

  tags = {
    Name    = "mini-crm-ec2"
    Project = "MiniCRM"
  }
}
