terraform {
  backend "s3" {
    # Bucket name, key, and region are passed at init time via -backend-config flags
    # in CI (see .github/workflows/terraform.yml) and locally via:
    #   terraform init \
    #     -backend-config="bucket=YOUR_BUCKET" \
    #     -backend-config="key=paymentology/terraform.tfstate" \
    #     -backend-config="region=us-east-1"
  }
}
