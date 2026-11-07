resource "aws_s3_directory_bucket" "fleet_cache" {
  bucket = "joshsymonds-ec2-fleet-cache--usw2-az1--x-s3"

  location {
    name = "usw2-az1"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "fleet_cache" {
  bucket = aws_s3_directory_bucket.fleet_cache.bucket

  rule {
    id     = "expire-cache"
    status = "Enabled"

    filter {}

    expiration {
      days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "fleet_cache_bucket" {
  # S3 lifecycle expiration runs as a service and needs a ReadWrite session to delete objects.
  statement {
    sid       = "LifecycleCreateSession"
    effect    = "Allow"
    actions   = ["s3express:CreateSession"]
    resources = [aws_s3_directory_bucket.fleet_cache.arn]

    principals {
      type        = "Service"
      identifiers = ["lifecycle.s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3express:SessionMode"
      values   = ["ReadWrite"]
    }
  }
}

resource "aws_s3_bucket_policy" "fleet_cache" {
  bucket = aws_s3_directory_bucket.fleet_cache.bucket
  policy = data.aws_iam_policy_document.fleet_cache_bucket.json
}

data "aws_iam_policy_document" "fleet_cache_trust" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fleet_cache" {
  name               = "ec2-fleet-cache"
  assume_role_policy = data.aws_iam_policy_document.fleet_cache_trust.json
}

data "aws_iam_policy_document" "fleet_cache" {
  # Boxes open a ReadWrite session on the cache bucket and nothing else.
  statement {
    sid       = "CacheCreateSession"
    effect    = "Allow"
    actions   = ["s3express:CreateSession"]
    resources = [aws_s3_directory_bucket.fleet_cache.arn]
  }
}

resource "aws_iam_role_policy" "fleet_cache" {
  role   = aws_iam_role.fleet_cache.name
  policy = data.aws_iam_policy_document.fleet_cache.json
}

resource "aws_iam_instance_profile" "fleet_cache" {
  name = "ec2-fleet-cache"
  role = aws_iam_role.fleet_cache.name
}
