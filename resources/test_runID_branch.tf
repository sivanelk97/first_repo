resource "aws_s3_bucket" "example" {
provider = aws.bucket_region
name = "test_runID_branch"
acl = "public"
}
