################################################################################
# S3 Gateway VPC Endpoint
#
# ECR image layers are stored in and served from S3
# (https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html),
# so without this endpoint every image pull by a node leaves the VPC through
# the NAT gateway and pays its per-GB data-processing fee. In one fork of this
# template, image-layer pulls were ~13% of a month's NAT gateway data
# processing. Gateway endpoints cost nothing — no hourly rate and no per-GB
# charge (https://aws.amazon.com/privatelink/pricing/) — and route same-region
# S3 traffic through an S3 prefix-list entry in the attached route tables
# instead, so this is pure savings for every cluster built from the template.
#
# Limits worth knowing:
#   - Same-region S3 only; cross-region and on-prem (DX/VPN) paths are
#     unaffected.
#   - This cluster is IPv6 (ip_family in main.tf), and IPv6-only pods reach
#     S3 via DNS64/NAT64, which still traverses — and pays for — the NAT
#     gateway. The endpoint fixes node-level traffic (image pulls happen over
#     the node's IPv4 stack); pod S3 traffic avoids NAT only when workloads
#     opt into S3 dual-stack endpoints (AWS_USE_DUALSTACK_ENDPOINT=true).
#
# The public route tables are attached too, so S3-bound traffic exiting the
# NAT gateway itself (e.g. that NAT64 pod path) reaches S3 through the
# endpoint rather than the internet gateway.
################################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)

  tags = merge(local.tags, {
    Name = "${local.name}-s3-gateway"
  })
}
