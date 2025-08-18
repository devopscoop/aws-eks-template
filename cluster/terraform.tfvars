admin_email    = "project1@devops.coop"
backend_s3_key = "project1-dev/terraform.tfstate"
cluster_name   = "project1-dev"

# If you changed dynamodb_table_name in bootstrap/terraform.tfvars, set this to the same value.
# dynamodb_table = "project1-dev-terraform-state-lock"

github_repos  = ["repo:devopscoop/project1-dev:*", ]
region        = "us-east-2"
tags_git_repo = "github.com/devopscoop/project1-dev"
tf_bucket     = "project1-dev-tf-state-us-east-2"
vpc_cidr      = "10.0.0.0/16"
zone_name     = "project1-dev.devops.coop"
