output "experiment_template_id" {
  description = "FIS Experiment Template ID. Start an experiment via: aws fis start-experiment --experiment-template-id <this-id>."
  value       = aws_fis_experiment_template.primary_eks_node_outage.id
}

output "experiment_template_arn" {
  description = "FIS Experiment Template ARN."
  value       = aws_fis_experiment_template.primary_eks_node_outage.arn
}

output "fis_service_role_arn" {
  description = "IAM role FIS assumes during experiment execution. Scoped to Karpenter-tagged EC2 only — see iam.tf."
  value       = aws_iam_role.fis.arn
}

output "stop_condition_alarm_name" {
  description = "CloudWatch alarm that aborts the experiment if triggered. For drill rehearsal: monitor its state in CloudWatch Console before starting the experiment."
  value       = aws_cloudwatch_metric_alarm.experiment_abort_signal.alarm_name
}

output "start_experiment_command" {
  description = "Copy-pasteable AWS CLI command to start the experiment. Retrieve via: terraform output -raw start_experiment_command."
  value       = "aws fis start-experiment --experiment-template-id ${aws_fis_experiment_template.primary_eks_node_outage.id} --region ${local.primary_region}"
}
