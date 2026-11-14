resource "aws_cloudwatch_log_group" "api" {
  name              = "/mini-crm/api"
  retention_in_days = 7

  tags = {
    Project     = "MiniCRM"
    Environment = "Dev"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "mini-crm-api-errors"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "?ERROR ?Exception ?Traceback"

  metric_transformation {
    name      = "ApplicationErrors"
    namespace = "MiniCRM/API"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_high" {
  alarm_name          = "MiniCRM-EC2-CPUHigh"
  alarm_description   = "CPU above 80% for two consecutive five-minute periods"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.crm.id
  }

  tags = {
    Project = "MiniCRM"
  }
}

resource "aws_cloudwatch_dashboard" "observability" {
  dashboard_name = "MiniCRM-Observability"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          region  = "eu-north-1"
          title   = "EC2 CPU"
          stat    = "Average"
          period  = 300
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.crm.id]]
        }
      },
      {
        type   = "log"
        width  = 24
        height = 8
        properties = {
          query  = "SOURCE '/mini-crm/api' | fields @timestamp, @message | sort @timestamp desc | limit 20"
          region = "eu-north-1"
          title  = "Mini CRM API logs"
          view   = "table"
        }
      }
    ]
  })
}
