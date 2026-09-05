#!/usr/bin/env bash
#
# ¿cuánto cuesta?.sh — list every node in the current kube-context with
# vCPU/memory and estimated monthly EC2 cost, a section for EBS-backed PVCs
# with their monthly cost, the EKS control plane fee, and a cluster total.
#
# Pricing sources:
#   - on-demand nodes (managed node groups, Karpenter on-demand/reserved):
#     AWS Pricing API (Linux, shared tenancy, no pre-installed software)
#   - spot nodes (Karpenter spot, SPOT node groups):
#     current spot price for the node's instance type in its availability zone
#   - EBS volumes: Pricing API GB-month rate per volume type, plus gp3
#     provisioned IOPS > 3000 and throughput > 125 MB/s, and io1/io2
#     provisioned IOPS (io2 priced at the first tier)
#   - EKS control plane: Pricing API cluster-hours rate for the region
#     (falls back to the $0.10/hr standard-support rate; extended support
#     for end-of-life Kubernetes versions bills 6x this and is not detected)
#
# Estimates cover EC2 instance-hours, EBS volumes behind PersistentVolumes,
# and the control plane only (no data transfer, snapshots, NAT, or spot-price
# drift over the month).
#
# Requires: kubectl, aws, jq
# IAM: pricing:GetProducts, ec2:DescribeSpotPriceHistory,
#      ec2:DescribeInstanceTypes, ec2:DescribeVolumes
#
# Usage: ./node-costs.sh
#   HOURS_PER_MONTH overrides the default of 730 (24 * 365 / 12).

set -euo pipefail

for cmd in kubectl aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' not found in PATH" >&2; exit 1; }
done

HOURS_PER_MONTH="${HOURS_PER_MONTH:-730}"
PRICING_API_REGION="us-east-1" # the Pricing API is only served from a few regions

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Pretty-print a TSV table from stdin: pad columns, right-align from column $1
# on, and draw a separator above the last (total) row.
render_table() {
  awk -F'\t' -v ralign="$1" '
    { rows = NR; nf[NR] = NF; for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
    END {
      for (r = 1; r <= rows; r++) {
        if (r == rows) { for (i = 1; i <= w[1]; i++) printf "-"; printf "\n" }
        for (i = 1; i <= nf[r]; i++)
          printf (i >= ralign ? "%*s  " : "%-*s  "), w[i], cell[r, i]
        printf "\n"
      }
    }'
}

# EBS rate lookup: ebs_rate <productFamily> <volumeApiName> → "price<TAB>unit"
# (highest non-zero price dimension, so tiered io2 uses its first tier).
ebs_rate() {
  aws pricing get-products \
      --region "$PRICING_API_REGION" \
      --service-code AmazonEC2 \
      --filters \
        "Type=TERM_MATCH,Field=productFamily,Value=$1" \
        "Type=TERM_MATCH,Field=volumeApiName,Value=$2" \
        "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
      --query 'PriceList[0]' --output text 2>/dev/null \
    | jq -r '
        ([.terms.OnDemand[].priceDimensions[] | select(.pricePerUnit.USD != "0")]
         | max_by(.pricePerUnit.USD | tonumber) // empty)
        | [.pricePerUnit.USD, .unit] | @tsv' 2>/dev/null \
    || true
}

# ── 1. Collect nodes: name, instance type, capacity type, zone, region, group ──
kubectl get nodes -o json | jq -r '
  .items[]
  | .metadata.labels as $l
  | [
      .metadata.name,
      ($l["node.kubernetes.io/instance-type"] // "unknown"),
      # managed node groups label ON_DEMAND/SPOT, Karpenter labels
      # on-demand/spot/reserved; normalize to lowercase-dashed
      (($l["karpenter.sh/capacity-type"] // $l["eks.amazonaws.com/capacityType"] // "on-demand")
        | ascii_downcase | gsub("_"; "-")),
      ($l["topology.kubernetes.io/zone"] // "unknown"),
      ($l["topology.kubernetes.io/region"] // "unknown"),
      (if $l["karpenter.sh/nodepool"] then "karpenter:" + $l["karpenter.sh/nodepool"]
       elif $l["eks.amazonaws.com/nodegroup"] then "nodegroup:" + $l["eks.amazonaws.com/nodegroup"]
       else "-" end)
    ]
  | @tsv' > "$workdir/nodes.tsv"

[ -s "$workdir/nodes.tsv" ] || { echo "no nodes found in the current kube-context" >&2; exit 1; }

REGION="$(awk -F'\t' '$5 != "unknown" {print $5; exit}' "$workdir/nodes.tsv")"
: "${REGION:?could not determine region from node labels}"

# ── 2. Instance specs (vCPU, memory) for every distinct instance type ──────────
: > "$workdir/prices.tsv"
all_types="$(awk -F'\t' '$2 != "unknown" {print $2}' "$workdir/nodes.tsv" | sort -u)"
if [ -n "$all_types" ]; then
  # shellcheck disable=SC2086  # word-splitting of $all_types is intentional
  aws ec2 describe-instance-types \
      --region "$REGION" \
      --instance-types $all_types \
      --query 'InstanceTypes[].[InstanceType, VCpuInfo.DefaultVCpus, MemoryInfo.SizeInMiB]' \
      --output text \
    | awk -v OFS='\t' '{print "spec", $1, $2, $3}' >> "$workdir/prices.tsv"
fi

# ── 3. On-demand $/hr per instance type (everything not labeled spot) ──────────
awk -F'\t' '$3 != "spot" {print $2}' "$workdir/nodes.tsv" | sort -u | while read -r itype; do
  [ "$itype" = "unknown" ] && continue
  price="$(aws pricing get-products \
      --region "$PRICING_API_REGION" \
      --service-code AmazonEC2 \
      --filters \
        "Type=TERM_MATCH,Field=instanceType,Value=$itype" \
        "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
        "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
        "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
        "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
        "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
      --query 'PriceList[0]' --output text 2>/dev/null \
    | jq -r '[.terms.OnDemand[].priceDimensions[].pricePerUnit.USD][0] // empty' 2>/dev/null \
    || true)"
  printf 'od\t%s\t%s\n' "$itype" "${price:-NA}" >> "$workdir/prices.tsv"
done

# ── 4. Current spot $/hr per (instance type, AZ) — one API call for all types ──
spot_types="$(awk -F'\t' '$3 == "spot" && $2 != "unknown" {print $2}' "$workdir/nodes.tsv" | sort -u)"
if [ -n "$spot_types" ]; then
  # shellcheck disable=SC2086  # word-splitting of $spot_types is intentional
  aws ec2 describe-spot-price-history \
      --region "$REGION" \
      --instance-types $spot_types \
      --product-descriptions "Linux/UNIX" "Linux/UNIX (Amazon VPC)" \
      --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --query 'SpotPriceHistory' --output json \
    | jq -r '
        sort_by(.Timestamp) | reverse
        | unique_by(.InstanceType + "/" + .AvailabilityZone)
        | .[]
        | ["spot", .InstanceType + "/" + .AvailabilityZone, .SpotPrice]
        | @tsv' >> "$workdir/prices.tsv"
fi

# ── 5. Join specs + prices onto nodes ──────────────────────────────────────────
awk -F'\t' -v OFS='\t' -v hrs="$HOURS_PER_MONTH" '
  NR == FNR {
    if ($1 == "spec") { vcpu[$2] = $3; mem[$2] = $4 / 1024 }
    else              { price[$1 FS $2] = $3 }
    next
  }
  {
    node = $1; itype = $2; cap = $3; zone = $4; group = $6
    key = (cap == "spot") ? "spot" FS itype "/" zone : "od" FS itype
    p = (key in price) ? price[key] : "NA"
    v = (itype in vcpu) ? vcpu[itype] : ""
    m = (itype in mem)  ? mem[itype]  : ""
    vs = (v == "") ? "?" : sprintf("%g", v)
    ms = (m == "") ? "?" : sprintf("%g", m)
    if (p == "NA" || p == "") {
      print node, itype, cap, zone, group, vs, ms, "?", "?"
    } else {
      print node, itype, cap, zone, group, vs, ms,
            sprintf("%.4f", p), sprintf("%.2f", p * hrs)
    }
  }' "$workdir/prices.tsv" "$workdir/nodes.tsv" \
  | sort -t"$(printf '\t')" -k9,9gr -k1,1 > "$workdir/body.tsv"

# ── 6. Render node table with totals ───────────────────────────────────────────
node_count="$(awk 'END {print NR}' "$workdir/body.tsv")"
node_unknown="$(awk -F'\t' '$9 == "?" {n++} END {print n + 0}' "$workdir/body.tsv")"
nodes_total="$(awk -F'\t' '$9 != "?" {t += $9} END {printf "%.2f", t + 0}' "$workdir/body.tsv")"

# Totals: vCPU/mem over all nodes; cost over priced nodes only
total_row="$(awk -F'\t' -v OFS='\t' -v n="$node_count" '
  $6 != "?" { tv += $6 }
  $7 != "?" { tm += $7 }
  $9 != "?" { th += $8; t += $9 }
  END {
    print "TOTAL (" n " nodes)", "", "", "", "",
          sprintf("%g", tv), sprintf("%g", tm),
          sprintf("%.4f", th), sprintf("%.2f", t)
  }' "$workdir/body.tsv")"

echo "Cluster: $(kubectl config current-context)   Region: $REGION   Hours/month: $HOURS_PER_MONTH"
echo
echo "NODES"
{
  printf 'NODE\tINSTANCE\tCAPACITY\tZONE\tGROUP\tVCPU\tMEM_GIB\t$/HR\t$/MONTH\n'
  cat "$workdir/body.tsv"
  printf '%s\n' "$total_row"
} | render_table 6

# ── 7. PVCs: EBS volumes behind PersistentVolumes ──────────────────────────────
kubectl get pv -o json > "$workdir/pv.json"

jq -r '
  .items[]
  | select(.spec.csi.driver? == "ebs.csi.aws.com")
  | [
      ((.spec.claimRef.namespace // "-") + "/" + (.spec.claimRef.name // "(unbound)")),
      .spec.csi.volumeHandle,
      (.spec.storageClassName // "-"),
      (.status.phase // "-")
    ]
  | @tsv' "$workdir/pv.json" > "$workdir/pvs.tsv"

non_ebs_pvs="$(jq '[.items[] | select(.spec.csi.driver? != "ebs.csi.aws.com")] | length' "$workdir/pv.json")"

pvc_total="0.00"
pvc_unknown=0
echo
echo "PVCs (EBS volumes)"
if [ -s "$workdir/pvs.tsv" ]; then
  : > "$workdir/ebs_lookup.tsv"

  vol_ids="$(cut -f2 "$workdir/pvs.tsv" | sort -u | paste -sd, -)"
  aws ec2 describe-volumes \
      --region "$REGION" \
      --filters "Name=volume-id,Values=$vol_ids" \
      --query 'Volumes[].[VolumeId, VolumeType, Size, Iops, Throughput]' \
      --output text \
    | awk -v OFS='\t' '{print "vol", $1, $2, $3, $4, $5}' >> "$workdir/ebs_lookup.tsv"

  for vtype in $(awk -F'\t' '$1 == "vol" {print $3}' "$workdir/ebs_lookup.tsv" | sort -u); do
    gb="$(ebs_rate Storage "$vtype" | cut -f1)"
    [ -n "$gb" ] && printf 'rate\tgb\t%s\t%s\n' "$vtype" "$gb" >> "$workdir/ebs_lookup.tsv"
    case "$vtype" in
      gp3)
        iops="$(ebs_rate "System Operation" gp3 | cut -f1)"
        [ -n "$iops" ] && printf 'rate\tiops\tgp3\t%s\n' "$iops" >> "$workdir/ebs_lookup.tsv"
        # throughput is priced per GiBps-month; normalize to per MiBps-month
        thr="$(ebs_rate "Provisioned Throughput" gp3 \
          | awk -F'\t' 'NF {r = $1; if ($2 ~ /GiBps/) r /= 1024; printf "%.6f", r}')"
        [ -n "$thr" ] && printf 'rate\tthr\tgp3\t%s\n' "$thr" >> "$workdir/ebs_lookup.tsv"
        ;;
      io1|io2)
        iops="$(ebs_rate "System Operation" "$vtype" | cut -f1)"
        [ -n "$iops" ] && printf 'rate\tiops\t%s\t%s\n' "$vtype" "$iops" >> "$workdir/ebs_lookup.tsv"
        ;;
    esac
  done

  awk -F'\t' -v OFS='\t' '
    NR == FNR {
      if ($1 == "rate") { rate[$2 FS $3] = $4 }
      else              { vt[$2] = $3; vsize[$2] = $4; viops[$2] = $5; vthr[$2] = $6 }
      next
    }
    {
      pvc = $1; vid = $2; sc = $3; phase = $4
      # a volume absent from describe-volumes no longer exists: a stale PV, $0
      if (!(vid in vt)) { print pvc, vid, sc, phase, "gone", "-", "-", "-", "0.00"; next }
      t = vt[vid]; size = vsize[vid]; iops = viops[vid]; thr = vthr[vid]
      cost = "?"
      if (("gb" FS t) in rate) {
        c = size * rate["gb" FS t]
        if (t == "gp3") {
          if (iops != "None" && iops > 3000 && (("iops" FS t) in rate)) c += (iops - 3000) * rate["iops" FS t]
          if (thr != "None" && thr > 125 && (("thr" FS t) in rate))     c += (thr - 125) * rate["thr" FS t]
        } else if ((t == "io1" || t == "io2") && iops != "None" && (("iops" FS t) in rate)) {
          c += iops * rate["iops" FS t]
        }
        cost = sprintf("%.2f", c)
      }
      print pvc, vid, sc, phase, t, size, (iops == "None" ? "-" : iops), (thr == "None" ? "-" : thr), cost
    }' "$workdir/ebs_lookup.tsv" "$workdir/pvs.tsv" \
    | sort -t"$(printf '\t')" -k9,9gr -k1,1 > "$workdir/pvc_body.tsv"

  pvc_count="$(awk 'END {print NR}' "$workdir/pvc_body.tsv")"
  pvc_unknown="$(awk -F'\t' '$9 == "?" {n++} END {print n + 0}' "$workdir/pvc_body.tsv")"
  pvc_gone="$(awk -F'\t' '$5 == "gone" {n++} END {print n + 0}' "$workdir/pvc_body.tsv")"
  pvc_total="$(awk -F'\t' '$9 != "?" {t += $9} END {printf "%.2f", t + 0}' "$workdir/pvc_body.tsv")"
  pvc_gib="$(awk -F'\t' '$6 ~ /^[0-9]/ {g += $6} END {printf "%g", g + 0}' "$workdir/pvc_body.tsv")"

  {
    printf 'PVC\tVOLUME_ID\tSTORAGECLASS\tSTATUS\tTYPE\tGIB\tIOPS\tMBPS\t$/MONTH\n'
    cat "$workdir/pvc_body.tsv"
    printf 'TOTAL (%s PVCs)\t\t\t\t\t%s\t\t\t%s\n' "$pvc_count" "$pvc_gib" "$pvc_total"
  } | render_table 6
else
  echo "(no EBS-backed PersistentVolumes found)"
fi
[ "$non_ebs_pvs" -gt 0 ] && echo "note: $non_ebs_pvs non-EBS PersistentVolume(s) not priced (e.g. EFS)"
[ "${pvc_gone:-0}" -gt 0 ] && echo "note: $pvc_gone PV(s) point at EBS volumes that no longer exist ('gone') — stale PVs, safe to clean up"

# ── 8. EKS control plane ───────────────────────────────────────────────────────
cp_hr="$(aws pricing get-products \
    --region "$PRICING_API_REGION" \
    --service-code AmazonEKS \
    --filters "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
    --output json 2>/dev/null \
  | jq -r '
      [.PriceList[] | fromjson
       | select(.product.attributes.usagetype | endswith("AmazonEKS-Hours:perCluster"))
       | .terms.OnDemand[].priceDimensions[].pricePerUnit.USD
       | select(. != "0")][0] // empty' 2>/dev/null \
  || true)"
cp_hr="$(awk -v p="${cp_hr:-0.10}" 'BEGIN {printf "%.4f", p}')"
cp_total="$(awk -v p="$cp_hr" -v h="$HOURS_PER_MONTH" 'BEGIN {printf "%.2f", p * h}')"

echo
echo "EKS CONTROL PLANE (standard support): \$${cp_hr}/hr = \$${cp_total}/month"

# ── 9. Grand total and warnings ────────────────────────────────────────────────
echo
grand="$(awk -v a="$nodes_total" -v b="$pvc_total" -v c="$cp_total" 'BEGIN {printf "%.2f", a + b + c}')"
echo "CLUSTER TOTAL: \$${grand}/month  (nodes \$${nodes_total} + EBS \$${pvc_total} + control plane \$${cp_total})"

if [ "$node_unknown" -gt 0 ] || [ "$pvc_unknown" -gt 0 ]; then
  echo
  echo "warning: $node_unknown node(s) and $pvc_unknown PVC(s) have no price ('?') and are excluded from totals" >&2
fi
