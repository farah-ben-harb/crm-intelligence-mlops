data "aws_iam_policy_document" "cloudwatch_logs_write" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]

    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
}

resource "aws_iam_policy" "cloudwatch_logs_write" {
  name   = "mini-crm-cloudwatch-logs-write"
  policy = data.aws_iam_policy_document.cloudwatch_logs_write.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs_write" {
  role       = aws_iam_role.crm_ec2.name
  policy_arn = aws_iam_policy.cloudwatch_logs_write.arn
}
