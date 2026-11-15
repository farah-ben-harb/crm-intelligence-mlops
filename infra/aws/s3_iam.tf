data "aws_iam_policy_document" "s3_model_read" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]

    resources = [
      "${aws_s3_bucket.models.arn}/models/*",
      "${aws_s3_bucket.models.arn}/candidates/*"
    ]
  }
}

resource "aws_iam_role_policy" "s3_model_read" {
  name   = "mini-crm-s3-model-read"
  role   = aws_iam_role.crm_ec2.id
  policy = data.aws_iam_policy_document.s3_model_read.json
}

