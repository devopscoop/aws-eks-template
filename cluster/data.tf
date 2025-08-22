# Finding AWS SSO roles so we can give them access to Kubernetes and KMS
data "aws_iam_roles" "administratoraccess" {
  name_regex  = "^AWSReservedSSO_AdministratorAccess"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}
data "aws_iam_roles" "viewonly" {
  name_regex  = "^AWSReservedSSO_ViewOnlyAccess"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}
