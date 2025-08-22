# If you want to use more variables from the `variables.tf` file, you will need to add them to both the `main.tf` file, and this one.

# Set this to your cluster name.
account_alias = "project1-dev"

region = "us-east-2"

# If you are not following AWS Well-Architected principle SEC01-BP01 of isolation of environments and workloads, https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_securely_operate_multi_accounts.html, you will need to adjust these settings:
# Uncomment this to prevent this code from setting your AWS account alias to your cluster name:
# manage_account_alias = false
# Uncomment this to add your cluster name as a prefix to the dynamodb_table_name, to avoid duplicate table names:
# dynamodb_table_name = "project1-dev-terraform-state-lock"
