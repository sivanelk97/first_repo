resource "aws_s3_bucket" "example" {
provider = aws.bucket_region
name = "fry457"
acl = "public"
}
