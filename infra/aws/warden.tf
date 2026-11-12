moved {
  from = aws_lambda_function.warden
  to   = aws_lambda_function.warden["us-west-2"]
}

moved {
  from = aws_cloudwatch_event_rule.warden_state
  to   = aws_cloudwatch_event_rule.warden_state["us-west-2"]
}

moved {
  from = aws_cloudwatch_event_target.warden_state
  to   = aws_cloudwatch_event_target.warden_state["us-west-2"]
}

moved {
  from = aws_lambda_permission.warden_state
  to   = aws_lambda_permission.warden_state["us-west-2"]
}

moved {
  from = aws_cloudwatch_event_rule.warden_schedule
  to   = aws_cloudwatch_event_rule.warden_schedule["us-west-2"]
}

moved {
  from = aws_cloudwatch_event_target.warden_schedule
  to   = aws_cloudwatch_event_target.warden_schedule["us-west-2"]
}

moved {
  from = aws_lambda_permission.warden_schedule
  to   = aws_lambda_permission.warden_schedule["us-west-2"]
}

import {
  to = aws_cloudwatch_log_group.warden["us-west-2"]
  id = "/aws/lambda/ec2-fleet-warden"
}

data "archive_file" "warden" {
  type        = "zip"
  source_file = "${path.module}/warden/handler.py"
  output_path = "${path.module}/.terraform/warden.zip"
}

resource "aws_iam_role" "warden" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "warden" {
  role = aws_iam_role.warden.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = flatten([for r in local.fleet_regions : [
          "arn:aws:logs:${r}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ec2-fleet-warden",
          "arn:aws:logs:${r}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ec2-fleet-warden:*",
        ]])
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = [for r in local.fleet_regions : "arn:aws:ec2:${r}:${data.aws_caller_identity.current.account_id}:instance/*"]
        Condition = {
          StringEquals = { "ec2:ResourceTag/fleet" = "ec2" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ec2:GetConsoleOutput"
        Resource = [for r in local.fleet_regions : "arn:aws:ec2:${r}:${data.aws_caller_identity.current.account_id}:instance/*"]
        Condition = {
          StringEquals = { "ec2:ResourceTag/fleet" = "ec2" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeVolumes"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DeleteVolume"
        Resource = [for r in local.fleet_regions : "arn:aws:ec2:${r}:${data.aws_caller_identity.current.account_id}:volume/*"]
        Condition = {
          StringEquals = { "ec2:ResourceTag/fleet" = "ec2" }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "warden" {
  for_each          = toset(local.fleet_regions)
  region            = each.key
  name              = "/aws/lambda/ec2-fleet-warden"
  retention_in_days = 30
}

resource "aws_lambda_function" "warden" {
  for_each         = toset(local.fleet_regions)
  region           = each.key
  function_name    = "ec2-fleet-warden"
  role             = aws_iam_role.warden.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.warden.output_path
  source_code_hash = data.archive_file.warden.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      FLEET_REGIONS = join(",", local.fleet_regions)
    }
  }

  depends_on = [aws_cloudwatch_log_group.warden]
}

resource "aws_cloudwatch_event_rule" "warden_state" {
  for_each = toset(local.fleet_regions)
  region   = each.key
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail      = { state = ["pending", "running"] }
  })
}

resource "aws_cloudwatch_event_target" "warden_state" {
  for_each = toset(local.fleet_regions)
  region   = each.key
  rule     = aws_cloudwatch_event_rule.warden_state[each.key].name
  arn      = aws_lambda_function.warden[each.key].arn
}

resource "aws_lambda_permission" "warden_state" {
  for_each      = toset(local.fleet_regions)
  region        = each.key
  statement_id  = "AllowEventBridgeWardenState"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.warden[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.warden_state[each.key].arn
}

resource "aws_cloudwatch_event_rule" "warden_schedule" {
  for_each            = toset(local.fleet_regions)
  region              = each.key
  schedule_expression = "rate(10 minutes)"
}

resource "aws_cloudwatch_event_target" "warden_schedule" {
  for_each = toset(local.fleet_regions)
  region   = each.key
  rule     = aws_cloudwatch_event_rule.warden_schedule[each.key].name
  arn      = aws_lambda_function.warden[each.key].arn
}

resource "aws_lambda_permission" "warden_schedule" {
  for_each      = toset(local.fleet_regions)
  region        = each.key
  statement_id  = "AllowEventBridgeWardenSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.warden[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.warden_schedule[each.key].arn
}
