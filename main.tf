#======================================================================================
# Terraform and Provider Requirements
#======================================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.21.0"
    }
  }
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
}

#======================================================================================
# S3 Buckets, Versioning, and Website Hosting
#======================================================================================
resource "aws_s3_bucket" "primary" {
  provider = aws.primary
  bucket   = var.primary_bucket_name
  tags = {
    "Name" = "Primary S3 Bucket"
    "Env"  = "POC"
  }
}

resource "aws_s3_bucket" "dr" {
  provider = aws.dr
  bucket   = var.dr_bucket_name
  tags = {
    "Name" = "DR S3 Bucket"
    "Env"  = "POC"
  }
}

resource "aws_s3_bucket_versioning" "primary_versioning" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "dr_versioning" {
  provider = aws.dr
  bucket   = aws_s3_bucket.dr.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_website_configuration" "primary_website" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary.id
  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_website_configuration" "dr_website" {
  provider = aws.dr
  bucket   = aws_s3_bucket.dr.id
  index_document {
    suffix = "index.html"
  }
}

#======================================================================================
# S3 Bucket Policy for CloudFront OAC (enables CloudFront access only)
#======================================================================================
resource "aws_s3_bucket_policy" "primary_policy" {
  provider = aws.primary
  bucket = aws_s3_bucket.primary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = "s3:GetObject"
        Resource = "${aws_s3_bucket.primary.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "dr_policy" {
  provider = aws.dr
  bucket = aws_s3_bucket.dr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = "s3:GetObject"
        Resource = "${aws_s3_bucket.dr.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

#======================================================================================
# Upload index.html and health.txt without ACL (bucket owner enforced)
#======================================================================================
resource "aws_s3_object" "primary_index" {
  provider     = aws.primary
  bucket       = aws_s3_bucket.primary.id
  key          = "index.html"
  source       = var.primary_index_file
  content_type = "text/html"
}

resource "aws_s3_object" "primary_health" {
  provider     = aws.primary
  bucket       = aws_s3_bucket.primary.id
  key          = "health.txt"
  source       = var.health_check_file
  content_type = "text/plain"
}

resource "aws_s3_object" "dr_index" {
  provider     = aws.dr
  bucket       = aws_s3_bucket.dr.id
  key          = "index.html"
  source       = var.dr_index_file
  content_type = "text/html"
}

#======================================================================================
# IAM Role & Policy for S3 CRR (unique name to avoid conflicts)
#======================================================================================
data "aws_iam_policy_document" "crr_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "s3_replication" {
  name               = "s3-crr-replication-role-unique"
  assume_role_policy = data.aws_iam_policy_document.crr_assume_role.json
}

data "aws_iam_policy_document" "crr_replication_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.primary.arn,
      aws_s3_bucket.dr.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObjectVersion",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging"
    ]
    resources = [
      "${aws_s3_bucket.primary.arn}/*",
      "${aws_s3_bucket.dr.arn}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags"
    ]
    resources = [
      "${aws_s3_bucket.primary.arn}/*",
      "${aws_s3_bucket.dr.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "s3_replication_policy" {
  name   = "s3-crr-replication-policy-unique"
  policy = data.aws_iam_policy_document.crr_replication_policy.json
}

resource "aws_iam_role_policy_attachment" "s3_replication_attach" {
  role       = aws_iam_role.s3_replication.name
  policy_arn = aws_iam_policy.s3_replication_policy.arn
}

#======================================================================================
# Bi-Directional Replication Configuration
#======================================================================================
resource "aws_s3_bucket_replication_configuration" "primary_to_dr" {
  provider   = aws.primary
  depends_on = [aws_s3_bucket_versioning.primary_versioning]
  bucket     = aws_s3_bucket.primary.id
  role       = aws_iam_role.s3_replication.arn

  rule {
    id     = "primary-to-dr"
    status = "Enabled"
    filter {}

    destination {
      bucket        = aws_s3_bucket.dr.arn
      storage_class = var.dr_storage_class
    }

    delete_marker_replication {
      status = "Enabled"
    }

    source_selection_criteria {
      replica_modifications {
        status = "Enabled"
      }
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "dr_to_primary" {
  provider   = aws.dr
  depends_on = [aws_s3_bucket_versioning.dr_versioning]
  bucket     = aws_s3_bucket.dr.id
  role       = aws_iam_role.s3_replication.arn

  rule {
    id     = "dr-to-primary"
    status = "Enabled"
    filter {}

    destination {
      bucket        = aws_s3_bucket.primary.arn
      storage_class = var.primary_storage_class
    }

    delete_marker_replication {
      status = "Enabled"
    }

    source_selection_criteria {
      replica_modifications {
        status = "Enabled"
      }
    }
  }
}

#======================================================================================
# Manual Failover Control for CloudFront Origin Group
#======================================================================================


resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "s3-oac-default"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.primary.bucket_regional_domain_name
    origin_id                = "primary-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
  }

  origin {
    domain_name              = aws_s3_bucket.dr.bucket_regional_domain_name
    origin_id                = "dr-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
  }

  origin_group {
    origin_id = "groupS3"
    failover_criteria {
      status_codes = var.failover_status_codes
    }
    member {
      origin_id = var.failover_mode == "primary" ? "primary-origin" : "dr-origin"
    }
    member {
      origin_id = var.failover_mode == "primary" ? "dr-origin" : "primary-origin"
    }
  }

  default_cache_behavior {
    target_origin_id        = "groupS3"
    viewer_protocol_policy  = "redirect-to-https"
    allowed_methods         = ["GET", "HEAD"]
    cached_methods          = ["GET", "HEAD"]
    min_ttl                 = var.cloudfront_min_ttl
    default_ttl             = var.cloudfront_default_ttl
    max_ttl                 = var.cloudfront_max_ttl

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

#======================================================================================
# Variables
#======================================================================================
variable "primary_region" {
  default = "us-east-1"
}

variable "dr_region" {
  default = "us-east-2"
}

variable "primary_bucket_name" {
  default = "app1-static-primary-unique0123"
}

variable "dr_bucket_name" {
  default = "app1-static-dr-unique0123"
}

variable "primary_index_file" {
  default = "primary-index.html"
}

variable "dr_index_file" {
  default = "dr-index.html"
}

variable "health_check_file" {
  default = "health.txt"
}

variable "dr_storage_class" {
  default = "INTELLIGENT_TIERING"
}

variable "primary_storage_class" {
  default = "STANDARD"
}

variable "failover_status_codes" {
  default = [403, 404, 500, 502, 503, 504]
}

variable "cloudfront_min_ttl" {
  default = 0
}

variable "cloudfront_default_ttl" {
  default = 3600
}

variable "cloudfront_max_ttl" {
  default = 86400
}

variable "failover_mode" {
  description = "Manual failover mode: primary or dr"
  type        = string
  default     = "primary"
}

#======================================================================================
# Outputs
#======================================================================================
output "cloudfront_distribution" {
  value       = aws_cloudfront_distribution.cdn.domain_name
  description = "CloudFront distribution domain (CDN endpoint)"
}
