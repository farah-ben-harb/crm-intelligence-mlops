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
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Mini CRM | Observability\nNative EC2 signals, the existing API error metric, and recent application logs. Dashboard refresh does not create or change infrastructure."
        }
      },
      {
        type       = "text"
        x          = 0
        y          = 2
        width      = 24
        height     = 1
        properties = { markdown = "## INFRASTRUCTURE HEALTH" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          region  = "eu-north-1"
          title   = "EC2 · CPU utilization"
          stat    = "Average"
          period  = 300
          yAxis   = { left = { min = 0, max = 100, label = "Percent" } }
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.crm.id, { label = "CPU (%)" }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          view   = "timeSeries"
          region = "eu-north-1"
          title  = "EC2 · Network traffic"
          stat   = "Sum"
          period = 300
          yAxis  = { left = { label = "Bytes / 5 min" } }
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.crm.id, { label = "Network in" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.crm.id, { label = "Network out" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          view   = "timeSeries"
          region = "eu-north-1"
          title  = "EC2 · Status checks"
          stat   = "Maximum"
          period = 60
          yAxis  = { left = { min = 0, max = 1, label = "Failed (0 = healthy)" } }
          metrics = [
            ["AWS/EC2", "StatusCheckFailed_Instance", "InstanceId", aws_instance.crm.id, { label = "Instance" }],
            ["AWS/EC2", "StatusCheckFailed_System", "InstanceId", aws_instance.crm.id, { label = "System" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          view   = "timeSeries"
          region = "eu-north-1"
          title  = "EC2 · EBS I/O (if published)"
          stat   = "Sum"
          period = 300
          yAxis  = { left = { label = "Operations / 5 min" } }
          metrics = [
            ["AWS/EC2", "EBSReadOps", "InstanceId", aws_instance.crm.id, { label = "Read ops" }],
            ["AWS/EC2", "EBSWriteOps", "InstanceId", aws_instance.crm.id, { label = "Write ops" }]
          ]
        }
      },
      {
        type       = "text"
        x          = 0
        y          = 15
        width      = 24
        height     = 1
        properties = { markdown = "## APPLICATION MONITORING" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          region  = "eu-north-1"
          title   = "API · Application errors"
          stat    = "Sum"
          period  = 300
          yAxis   = { left = { min = 0, label = "Errors / 5 min" } }
          metrics = [["MiniCRM/API", "ApplicationErrors", { label = "Matched error events" }]]
        }
      },
      {
        type   = "text"
        x      = 12
        y      = 16
        width  = 12
        height = 6
        properties = {
          markdown = "### Telemetry boundaries\nRequest counts, status-code rates and latency are not graphed because reliable structured HTTP fields have not been verified. `ApplicationErrors` counts matching ERROR / Exception / Traceback text in the shared log group; it does not classify deployment versus application origin. Review event context below. Memory and filesystem usage require an agent or application instrumentation and are intentionally not shown."
        }
      },
      {
        type       = "text"
        x          = 0
        y          = 22
        width      = 24
        height     = 1
        properties = { markdown = "## RELIABILITY & ALERTING" }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 23
        width  = 12
        height = 4
        properties = {
          title  = "EC2 · CPU alarm state"
          alarms = [aws_cloudwatch_metric_alarm.ec2_cpu_high.arn]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 23
        width  = 12
        height = 4
        properties = {
          view    = "timeSeries"
          region  = "eu-north-1"
          title   = "API · Error history"
          stat    = "Sum"
          period  = 300
          yAxis   = { left = { min = 0, label = "Errors / 5 min" } }
          metrics = [["MiniCRM/API", "ApplicationErrors", { label = "Matched error events" }]]
        }
      },
      {
        type       = "text"
        x          = 0
        y          = 27
        width      = 24
        height     = 1
        properties = { markdown = "## OPERATIONS" }
      },
      {
        type   = "log"
        x      = 0
        y      = 28
        width  = 12
        height = 8
        properties = {
          query  = "SOURCE '/mini-crm/api' | fields @timestamp, @message | sort @timestamp desc | limit 25"
          region = "eu-north-1"
          title  = "Recent API container logs"
          view   = "table"
        }
      },
      {
        type   = "text"
        x      = 12
        y      = 28
        width  = 12
        height = 8
        properties = {
          markdown = "### Monitored services\n- **API:** FastAPI in Docker on the existing EC2 instance\n- **Application logs:** `/mini-crm/api` · 7-day retention\n- **Error signal:** `MiniCRM/API · ApplicationErrors`\n- **Alert:** `MiniCRM-EC2-CPUHigh`\n\n[Open the log group](https://eu-north-1.console.aws.amazon.com/cloudwatch/home?region=eu-north-1#logsV2:log-groups/log-group/%252Fmini-crm%252Fapi) · [Open CloudWatch alarms](https://eu-north-1.console.aws.amazon.com/cloudwatch/home?region=eu-north-1#alarmsV2:)"
        }
      }
    ]
  })
}
