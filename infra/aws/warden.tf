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
        Resource = [
          "arn:aws:logs:us-west-2:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ec2-fleet-warden",
          "arn:aws:logs:us-west-2:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ec2-fleet-warden:*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = "arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:instance/*"
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
        Resource = "arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:volume/*"
        Condition = {
          StringEquals = { "ec2:ResourceTag/fleet" = "ec2" }
        }
      },
    ]
  })
}

resource "aws_lambda_function" "warden" {
  function_name    = "ec2-fleet-warden"
  role             = aws_iam_role.warden.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.warden.output_path
  source_code_hash = data.archive_file.warden.output_base64sha256
  timeout          = 60
}

resource "aws_cloudwatch_event_rule" "warden_state" {
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail      = { state = ["pending", "running"] }
  })
}

resource "aws_cloudwatch_event_target" "warden_state" {
  rule = aws_cloudwatch_event_rule.warden_state.name
  arn  = aws_lambda_function.warden.arn
}

resource "aws_lambda_permission" "warden_state" {
  statement_id  = "AllowEventBridgeWardenState"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.warden.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.warden_state.arn
}

resource "aws_cloudwatch_event_rule" "warden_schedule" {
  schedule_expression = "rate(10 minutes)"
}

resource "aws_cloudwatch_event_target" "warden_schedule" {
  rule = aws_cloudwatch_event_rule.warden_schedule.name
  arn  = aws_lambda_function.warden.arn
}

resource "aws_lambda_permission" "warden_schedule" {
  statement_id  = "AllowEventBridgeWardenSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.warden.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.warden_schedule.arn
}
