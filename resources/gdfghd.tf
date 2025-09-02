resource "aws_s3_bucket" "example" {
provider = aws.bucket_region
name = "gdfghd"
acl = "public"
}
