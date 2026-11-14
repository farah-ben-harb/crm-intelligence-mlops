output "cloudwatch_log_group_name" {
  value = aws_cloudwatch_log_group.api.name
}

output "cloudwatch_cpu_alarm_name" {
  value = aws_cloudwatch_metric_alarm.ec2_cpu_high.alarm_name
}

output "cloudwatch_dashboard_name" {
  value = aws_cloudwatch_dashboard.observability.dashboard_name
}
