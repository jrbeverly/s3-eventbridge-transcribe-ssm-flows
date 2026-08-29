resource "aws_s3_bucket" "source" {
  bucket_prefix = "${local.bucket_prefix}-source-"
  force_destroy = true

  tags = {
    Name           = "${var.environment}-source"
    Responsibility = "SourceMedia"
  }
}

resource "aws_s3_bucket_ownership_controls" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket = aws_s3_bucket.source.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "publication_adapter" {
  bucket_prefix = "${local.bucket_prefix}-publication-"
  force_destroy = true

  tags = {
    Name           = "${var.environment}-publication-adapter"
    Responsibility = "ExternalPublicationDestination"
  }
}

resource "aws_s3_bucket_ownership_controls" "publication_adapter" {
  bucket = aws_s3_bucket.publication_adapter.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "publication_adapter" {
  bucket = aws_s3_bucket.publication_adapter.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "publication_adapter" {
  bucket = aws_s3_bucket.publication_adapter.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "publication_adapter" {
  bucket = aws_s3_bucket.publication_adapter.id

  versioning_configuration {
    status = "Enabled"
  }
}
