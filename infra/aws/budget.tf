resource "aws_budgets_budget" "fleet" {
  name         = "ec2-fleet"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["josh@savecraft.gg"]
  }
}

# Deny policy the budget action attaches to the launcher at 100% of budget.
data "aws_iam_policy_document" "launcher_deny" {
  statement {
    effect    = "Deny"
    actions   = ["ec2:RunInstances", "ebs:StartSnapshot"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "launcher_deny" {
  name   = "ec2-fleet-launcher-deny"
  policy = data.aws_iam_policy_document.launcher_deny.json
}

data "aws_iam_policy_document" "budget_action_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "budget_action" {
  assume_role_policy = data.aws_iam_policy_document.budget_action_trust.json
}

data "aws_iam_policy_document" "budget_action" {
  statement {
    effect    = "Allow"
    actions   = ["iam:AttachUserPolicy", "iam:DetachUserPolicy"]
    resources = [aws_iam_user.launcher.arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [aws_iam_policy.launcher_deny.arn]
    }
  }
}

resource "aws_iam_role_policy" "budget_action" {
  role   = aws_iam_role.budget_action.id
  policy = data.aws_iam_policy_document.budget_action.json
}

resource "aws_budgets_budget_action" "fleet" {
  budget_name        = aws_budgets_budget.fleet.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  # The action attaches the deny policy with this role, so the role policy must exist first.
  depends_on = [aws_iam_role_policy.budget_action]

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.launcher_deny.arn
      users      = [aws_iam_user.launcher.name]
    }
  }

  subscriber {
    address           = "josh@savecraft.gg"
    subscription_type = "EMAIL"
  }
}
