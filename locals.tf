locals {
  common_tags = merge(
    var.additional_tags,
    {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
    },
  )

  # bucket_prefix accepts at most 37 characters and the longest suffix added
  # below is "-publication-", leaving 24 characters for the environment.
  bucket_prefix = substr(var.environment, 0, 24)

  ssm_parameter_prefix = "/${var.project_name}/${var.environment}"

  # The boto3 in SSM executeScript runtimes predates the S3 object annotation
  # API, so the two operations are merged into its model as botocore sdk-extras.
  s3_annotation_model_prelude = <<-PYTHON
    import os
    import pathlib
    _models = pathlib.Path("/tmp/botocore-models/s3/2006-03-01")
    _models.mkdir(parents=True, exist_ok=True)
    (_models / "service-2.sdk-extras.json").write_text(r'''${file("${path.module}/s3-annotation-model.json")}''')
    os.environ["AWS_DATA_PATH"] = "/tmp/botocore-models"
  PYTHON
}
