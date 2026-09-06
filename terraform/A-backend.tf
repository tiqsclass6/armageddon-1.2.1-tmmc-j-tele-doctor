terraform {
  backend "s3" {
    bucket  = "armageddon-tiqs-state-files" # Name of the S3 bucket
    key     = "armageddon-class6.tfstate"   # The name of the state file in the bucket
    region  = "us-east-1"                   # Use a variable for the region
    encrypt = true                          # Enable server-side encryption (optional but recommended)
  }
}