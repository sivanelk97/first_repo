resource "aws_s3_bucket" "example" {
provider = aws.bucket_region
name = "dfheth457456"
acl = "public"
}
