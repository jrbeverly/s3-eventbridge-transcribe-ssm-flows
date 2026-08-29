locals {
  # The adapter currently bound to the external publication destination. The
  # publication target parameter is meaningless without it, so the two are
  # published together and replaced together.
  publication_adapter_type = "s3"
}

resource "aws_ssm_parameter" "source_bucket_name" {
  name        = "${local.ssm_parameter_prefix}/source/bucket-name"
  description = "Physical name of the bucket that receives source media."
  type        = "String"
  value       = aws_s3_bucket.source.id

  tags = {
    Responsibility = "SourceMedia"
  }
}

resource "aws_ssm_parameter" "publication_adapter_type" {
  name        = "${local.ssm_parameter_prefix}/publication/adapter-type"
  description = "Adapter that performs external media publication and determines how the publication target is interpreted."
  type        = "String"
  value       = local.publication_adapter_type

  tags = {
    Responsibility = "ExternalPublicationDestination"
  }
}

resource "aws_ssm_parameter" "publication_target" {
  name        = "${local.ssm_parameter_prefix}/publication/target"
  description = "Destination the publication adapter writes to, interpreted according to the adapter type. The s3 adapter reads it as a bucket name."
  type        = "String"
  value       = aws_s3_bucket.publication_adapter.id

  tags = {
    Responsibility = "ExternalPublicationDestination"
  }
}
