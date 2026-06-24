#!/usr/bin/env bash

# Launch a one-time S3 Batch Replication job per Loki source bucket, to backfill
# objects that existed before live cross-region replication was enabled (see
# loki.tf). Live replication only copies objects written *after* it is turned
# on, so this is how the pre-existing log chunks/index get to the replica region.
#
# The AWS provider has no resource for S3 Batch Operations jobs, so the jobs are
# created here via the AWS CLI, using the IAM role and bucket ARNs that loki.tf
# publishes in the `loki_batch_replication` output.
#
# Prerequisites: a completed `tofu apply` (buckets, replication config, and the
# batch-replication IAM role must exist), plus the aws CLI, jq, and tofu.
# Re-running is safe: the manifest only targets objects whose replication status
# is NONE or FAILED, so already-replicated objects are skipped.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

config=$(tofu -chdir="${SCRIPT_DIR}" output -json loki_batch_replication)
account_id=$(jq -r '.account_id' <<< "$config")
region=$(jq -r '.region' <<< "$config")
role_arn=$(jq -r '.role_arn' <<< "$config")

# One job per source bucket. The destination is taken from each bucket's own
# replication configuration, so we only point the job at the source.
while IFS=$'\t' read -r name bucket_arn; do
  echo "Creating S3 Batch Replication job for ${name} (${bucket_arn})..."

  manifest_generator=$(jq -nc \
    --arg owner "$account_id" \
    --arg src "$bucket_arn" \
    '{S3JobManifestGenerator: {
        ExpectedBucketOwner: $owner,
        SourceBucket: $src,
        EnableManifestOutput: false,
        Filter: {
          EligibleForReplication: true,
          ObjectReplicationStatuses: ["NONE", "FAILED"]
        }
      }}')

  job_id=$(aws s3control create-job \
    --region "$region" \
    --account-id "$account_id" \
    --priority 1 \
    --role-arn "$role_arn" \
    --no-confirmation-required \
    --operation '{"S3ReplicateObject": {}}' \
    --report '{"Enabled": false}' \
    --manifest-generator "$manifest_generator" \
    --query JobId --output text)

  echo "  -> JobId ${job_id}"
done < <(jq -r '.source_buckets | to_entries[] | "\(.key)\t\(.value)"' <<< "$config")

echo "Done. Track progress under S3 > Batch Operations in ${region}."
