locals {
  allowed_instance_types = [
    "c8a.medium", "c8a.large", "c8a.xlarge", "c8a.2xlarge", "c8a.4xlarge", "c8a.8xlarge", "c8a.12xlarge", "c8a.16xlarge",
    "m8a.medium", "m8a.large", "m8a.xlarge", "m8a.2xlarge", "m8a.4xlarge", "m8a.8xlarge", "m8a.12xlarge", "m8a.16xlarge",
    "r8a.medium", "r8a.large", "r8a.xlarge", "r8a.2xlarge", "r8a.4xlarge", "r8a.8xlarge", "r8a.12xlarge", "r8a.16xlarge",
  ]
}

resource "aws_iam_user" "launcher" {
  name = "ec2-fleet-launcher"
}

data "aws_iam_policy_document" "launcher" {
  # Read-only describes and pricing lookups.
  statement {
    sid       = "Read"
    effect    = "Allow"
    actions   = ["ec2:Describe*", "ebs:ListSnapshotBlocks"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-west-2"]
    }
  }

  statement {
    sid       = "PricingGetProducts"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  # Launch: instances must carry fleet=ec2 and an allowlisted type.
  statement {
    sid       = "RunInstancesInstance"
    effect    = "Allow"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/fleet"
      values   = ["ec2"]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = local.allowed_instance_types
    }
  }

  statement {
    sid       = "RunInstancesVolume"
    effect    = "Allow"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:volume/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/fleet"
      values   = ["ec2"]
    }
  }

  statement {
    sid       = "RunInstancesSecurityGroup"
    effect    = "Allow"
    actions   = ["ec2:RunInstances"]
    resources = [aws_security_group.fleet.arn]
  }

  statement {
    sid       = "RunInstancesOwnImage"
    effect    = "Allow"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:us-west-2::image/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:Owner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid     = "RunInstancesNetwork"
    effect  = "Allow"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:subnet/*",
      "arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:network-interface/*",
    ]
  }

  # Tagging, only as part of creating a resource.
  statement {
    sid     = "CreateTagsOnCreate"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:*/*",
      "arn:aws:ec2:us-west-2::image/*",
      "arn:aws:ec2:us-west-2::snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "RegisterImage"]
    }
  }

  # Base image upload: snapshot start, blocks, completion, and registration.
  statement {
    sid       = "StartSnapshotBase"
    effect    = "Allow"
    actions   = ["ebs:StartSnapshot"]
    resources = ["arn:aws:ec2:us-west-2::snapshot/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/fleet"
      values   = ["ec2-base"]
    }
  }

  # StartSnapshot is the only action that can tag a snapshot on create.
  statement {
    sid       = "TagSnapshotOnStartBase"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:us-west-2::snapshot/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/fleet"
      values   = ["ec2-base"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["fleet"]
    }
  }

  statement {
    sid    = "UploadSnapshotAndRegister"
    effect = "Allow"
    actions = [
      "ebs:PutSnapshotBlock",
      "ebs:CompleteSnapshot",
      "ec2:RegisterImage",
    ]
    resources = [
      "arn:aws:ec2:us-west-2::snapshot/*",
      "arn:aws:ec2:us-west-2::image/*",
    ]
  }

  # Cleanup is limited to base-tagged images and snapshots.
  statement {
    sid     = "CleanupBaseImage"
    effect  = "Allow"
    actions = ["ec2:DeregisterImage", "ec2:DeleteSnapshot"]
    resources = [
      "arn:aws:ec2:us-west-2::image/*",
      "arn:aws:ec2:us-west-2::snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/fleet"
      values   = ["ec2-base"]
    }
  }

  # Terminate only fleet=ec2 instances.
  statement {
    sid       = "TerminateFleetInstances"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:us-west-2:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/fleet"
      values   = ["ec2"]
    }
  }
}

# Customer managed, not inline: IAM caps user inline policies at 2,048 characters.
resource "aws_iam_policy" "launcher" {
  name   = "ec2-fleet-launcher"
  policy = data.aws_iam_policy_document.launcher.json
}

resource "aws_iam_user_policy_attachment" "launcher" {
  user       = aws_iam_user.launcher.name
  policy_arn = aws_iam_policy.launcher.arn
}

resource "aws_iam_access_key" "launcher" {
  user = aws_iam_user.launcher.name
}
