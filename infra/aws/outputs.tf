output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "vpc_cidr" {
  value = data.aws_vpc.default.cidr_block
}

output "subnet_ids" {
  value = data.aws_subnets.existing.ids
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "ec2_instance_profile" {
  value = aws_iam_instance_profile.crm.name
}

output "ec2_instance_id" {
  value = aws_instance.crm.id
}

output "ec2_public_ip" {
  value = aws_instance.crm.public_ip
}
