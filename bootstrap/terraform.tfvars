# If you want to more variables from `variables.tf`, you need to add them to `main.tf`, then add them here.

# Set this to the name of your cluster.
account_alias = "project1-dev"

region        = "us-east-2"

# If you are not following AWS Well-Architected principle SEC01-BP01 of isolation of environments and workloads, then you should set manage_account_alias to false, otherwise this code set your AWS account alias to your EKS cluster name.
# https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_securely_operate_multi_accounts.html
# manage_account_alias = false
