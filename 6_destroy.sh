#!/bin/bash
# ลบทุกอย่างของ environment ตามลำดับ รันซ้ำได้ (ข้ามของที่ไม่มีแล้ว) และสรุปตอนจบว่าอะไรยังเหลือ
# ใช้: ./6_destroy.sh                      ถามยืนยัน (ต้องพิมพ์ชื่อ environment)
#      ./6_destroy.sh --yes                ไม่ถาม
#      NO_FINAL_SNAPSHOT=1 ./6_destroy.sh  ลบ RDS โดยไม่เก็บ final snapshot (default: เก็บ <LAB_NAME>-final-<เวลา>)
#      DELETE_S3=1 ./6_destroy.sh          ล้างและลบ S3 bucket ด้วย (default: ปล่อยไว้ แค่เตือน)
# ลำดับ: app ใน k8s → ปิด deletion protection + สั่งลบ RDS, terminate EC2 (คู่ขนาน) → EIP → รอ RDS → subnet group → alarm/SNS → SG → VPC → IAM → S3 → Tunnel + CNAME → ไฟล์
set -uo pipefail   # ไม่ใช้ -e เพื่อให้ทำทุกขั้นจนจบแล้วรายงานสิ่งที่ลบไม่ได้
source "$(dirname "$0")/common.sh"
need_tools aws jq; need_aws
NO_FINAL_SNAPSHOT=${NO_FINAL_SNAPSHOT:-0}; DELETE_S3=${DELETE_S3:-0}
BUCKET=$(s3_bucket)

if [[ "${1:-}" != "--yes" ]]; then
  echo "จะลบ PROD: EC2/VPC $LAB_NAME, RDS $DB_ID (final snapshot: $([[ $NO_FINAL_SNAPSHOT == 1 ]] && echo ไม่เก็บ || echo เก็บ)), IAM $ROLE_NAME + $S3_USER, S3 $BUCKET ($([[ $DELETE_S3 == 1 ]] && echo ลบ || echo ปล่อยไว้)), tunnel $TUNNEL_NAME"
  read -rp "พิมพ์ $LAB_NAME เพื่อยืนยัน: " CONFIRM
  [[ "$CONFIRM" == "$LAB_NAME" ]] || { echo "ยกเลิก"; exit 1; }
fi
VPC_ID=$(lab_vpc)

# ---- 1) app ใน k8s (best effort: ปิด connector ของ tunnel ให้เรียบร้อยก่อนเครื่องหาย) ----
step "1) ลบ workload ใน k3s"
if [[ -s kubeconfig ]] && api_up && kubectl get ns --request-timeout=10s > /dev/null 2>&1; then
  kubectl delete deploy api bo cloudflared --ignore-not-found --timeout=60s > /dev/null 2>&1 \
    && ok "ลบ deployment แล้ว" || warn "ลบ deployment ไม่สำเร็จ (จะหายไปพร้อมเครื่องอยู่ดี)"
else
  skip "ต่อ cluster ไม่ได้ (ไม่ได้เปิด ./connect_k8s.sh?) ข้าม deployment จะหายไปพร้อมเครื่องอยู่ดี"
fi

# ---- 2) RDS (ปิด deletion protection ก่อน แล้วสั่งลบ ไปทำอย่างอื่นระหว่างรอ) ----
step "2) สั่งลบ RDS $DB_ID"
DB_STATUS=$(rds_status)
case "$DB_STATUS" in
  none)     skip "ไม่มี RDS แล้ว" ;;
  deleting) ok "กำลังลบอยู่แล้ว" ;;
  *)
    if [[ "$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query DBInstances[0].DeletionProtection --output text)" == "True" ]]; then
      aws rds modify-db-instance --db-instance-identifier "$DB_ID" --no-deletion-protection --apply-immediately --no-cli-pager > /dev/null \
        && ok "ปิด deletion protection" || warn "ปิด deletion protection ไม่ได้"
      aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
    fi
    if [[ "$NO_FINAL_SNAPSHOT" == 1 ]]; then
      aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups --no-cli-pager > /dev/null \
        && ok "สั่งลบแล้ว ไม่เก็บ snapshot (รอตอนท้าย)" || warn "สั่งลบ RDS ไม่สำเร็จ"
    else
      FINAL=$(snapshot_id final)
      aws rds delete-db-instance --db-instance-identifier "$DB_ID" --final-db-snapshot-identifier "$FINAL" --delete-automated-backups --no-cli-pager > /dev/null \
        && ok "สั่งลบแล้ว เก็บ final snapshot $FINAL (มีค่าเก็บ ~\$0.095/GB-เดือน ลบเองเมื่อไม่ใช้: aws rds delete-db-snapshot --db-snapshot-identifier $FINAL)" \
        || warn "สั่งลบ RDS ไม่สำเร็จ"
    fi ;;
esac

# ---- 3) EC2 ทุกตัว (server + agent) ----
step "3) terminate EC2 ของ environment"
IDS="$(instance_ids server) $(instance_ids agent)"; IDS=${IDS//  / }; IDS=${IDS# }; IDS=${IDS% }
if [[ -n "$IDS" ]]; then
  aws ec2 terminate-instances --instance-ids $IDS > /dev/null && ok "สั่ง terminate: $IDS" || warn "terminate ไม่สำเร็จ: $IDS"
  echo "  รอ instance terminated..."
  aws ec2 wait instance-terminated --instance-ids $IDS && ok "terminated แล้ว" || warn "instance ยังไม่ terminated: $IDS"
else
  skip "ไม่มี instance แล้ว"
fi

# ---- 4) Elastic IP ----
step "4) ปล่อย Elastic IP"
ALLOC=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$LAB_NAME" --query "Addresses[0].AllocationId" --output text | sed '/^None$/d')
if [[ -n "$ALLOC" ]]; then
  aws ec2 release-address --allocation-id "$ALLOC" && ok "ปล่อย $ALLOC แล้ว" || warn "ปล่อย EIP $ALLOC ไม่ได้"
else
  skip "ไม่มี EIP แล้ว"
fi

# ---- 5) รอ RDS หาย แล้วลบ subnet group ----
step "5) รอ RDS ถูกลบ"
if [[ "$DB_STATUS" != "none" ]]; then
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" && ok "RDS ลบแล้ว" || warn "RDS ยังอยู่"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" > /dev/null 2>&1 \
  && ok "ลบ subnet group $SUBNET_GROUP" || skip "ไม่มี subnet group แล้ว"

# ---- 6) CloudWatch alarm + SNS ----
step "6) ลบ alarm และ SNS topic"
ALARMS=$(aws cloudwatch describe-alarms --alarm-name-prefix "$LAB_NAME-rds-" --query "MetricAlarms[].AlarmName" --output text)
[[ -n "$ALARMS" ]] && { aws cloudwatch delete-alarms --alarm-names $ALARMS && ok "ลบ alarm: $ALARMS" || warn "ลบ alarm ไม่ได้"; } || skip "ไม่มี alarm"
TOPIC=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':$LAB_NAME-alarms')].TopicArn" --output text)
[[ -n "$TOPIC" ]] && { aws sns delete-topic --topic-arn "$TOPIC" && ok "ลบ topic $LAB_NAME-alarms" || warn "ลบ SNS topic ไม่ได้"; } || skip "ไม่มี SNS topic"

# ---- 7) Security group (RDS SG อ้างถึง node SG จึงต้องลบก่อน; ล้าง rule ก่อนลบเพราะ node SG อ้างถึงตัวเอง) ----
step "7) ลบ security group"
for name in "$SG_NAME" "$NODE_SG"; do
  SG=$(sg_id "$name")
  if [[ -z "$SG" ]]; then skip "ไม่มี $name แล้ว"; continue; fi
  RULES=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" \
    --query "SecurityGroupRules[?IsEgress==\`false\`].SecurityGroupRuleId" --output text)
  [[ -n "$RULES" ]] && aws ec2 revoke-security-group-ingress --group-id "$SG" --security-group-rule-ids $RULES > /dev/null 2>&1
  del_sg() { aws ec2 delete-security-group --group-id "$SG" 2> /dev/null; }   # ENI ของ RDS/EC2 ปล่อยช้ากว่าตัว resource จึง retry
  wait_for "ENI ปล่อย SG $name" 10 12 del_sg && ok "ลบ $name ($SG)" || warn "ลบ SG $name ($SG) ไม่ได้ ยังมี ENI อ้างอิงอยู่"
done

# ---- 8) VPC ----
step "8) ลบ VPC $LAB_NAME"
if [[ -n "$VPC_ID" ]]; then
  for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text); do
    aws ec2 delete-subnet --subnet-id "$s" && ok "ลบ subnet $s" || warn "ลบ subnet $s ไม่ได้"
  done
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text); do
    aws ec2 delete-route-table --route-table-id "$rt" && ok "ลบ route table $rt" || warn "ลบ route table $rt ไม่ได้"
  done
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" \
      && aws ec2 delete-internet-gateway --internet-gateway-id "$igw" && ok "ลบ IGW $igw" || warn "ลบ IGW $igw ไม่ได้"
  done
  aws ec2 delete-vpc --vpc-id "$VPC_ID" && ok "ลบ VPC $VPC_ID" || warn "ลบ VPC $VPC_ID ไม่ได้ (ดู ../aws-eks-alb-acm-cloudflare-app-rds-lab/delete_vpc.sh $VPC_ID)"
else
  skip "ไม่มี VPC แล้ว"
fi

# ---- 9) IAM: role ของ node + user ของ S3 ----
step "9) ลบ IAM role/instance profile $ROLE_NAME และ user $S3_USER"
if aws iam get-instance-profile --instance-profile-name "$ROLE_NAME" > /dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME" 2> /dev/null
  aws iam delete-instance-profile --instance-profile-name "$ROLE_NAME" && ok "ลบ instance profile" || warn "ลบ instance profile ไม่ได้"
else
  skip "ไม่มี instance profile แล้ว"
fi
if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  for p in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyArn" --output text); do
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$p"
  done
  aws iam delete-role --role-name "$ROLE_NAME" && ok "ลบ role" || warn "ลบ role ไม่ได้"
else
  skip "ไม่มี role แล้ว"
fi
if aws iam get-user --user-name "$S3_USER" > /dev/null 2>&1; then
  for k in $(aws iam list-access-keys --user-name "$S3_USER" --query "AccessKeyMetadata[].AccessKeyId" --output text); do
    aws iam delete-access-key --user-name "$S3_USER" --access-key-id "$k"
  done
  for p in $(aws iam list-user-policies --user-name "$S3_USER" --query "PolicyNames[]" --output text); do
    aws iam delete-user-policy --user-name "$S3_USER" --policy-name "$p"
  done
  aws iam delete-user --user-name "$S3_USER" && ok "ลบ user $S3_USER (+ access key)" || warn "ลบ user $S3_USER ไม่ได้"
else
  skip "ไม่มี user $S3_USER แล้ว"
fi

# ---- 10) S3 ----
step "10) S3 bucket $BUCKET"
if ! aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
  skip "ไม่มี bucket แล้ว"
elif [[ "$DELETE_S3" != 1 ]]; then
  warn "ปล่อย bucket $BUCKET ไว้ (ไฟล์ของผู้ใช้) ถ้าต้องการลบ: DELETE_S3=1 ./6_destroy.sh"
else
  empty_bucket() {   # ลบทุก version + delete marker ทีละ 1000 (bucket เปิด versioning ไว้ s3 rb --force ไม่พอ)
    local page objs n
    while :; do
      page=$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 --output json \
        --query '{V: Versions[].{Key:Key,VersionId:VersionId}, D: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')
      objs=$(jq -c '{Objects: (((.V // []) + (.D // []))[:1000]), Quiet: true}' <<< "$page")
      n=$(jq '.Objects | length' <<< "$objs"); [[ "$n" -eq 0 ]] && break
      aws s3api delete-objects --bucket "$BUCKET" --delete "$objs" > /dev/null || return 1
      echo "    ลบ $n object"
    done
  }
  empty_bucket && aws s3api delete-bucket --bucket "$BUCKET" && ok "ลบ bucket $BUCKET" || warn "ลบ bucket $BUCKET ไม่ได้"
fi

# ---- 11) Cloudflare ----
step "11) Cloudflare: tunnel $TUNNEL_NAME + CNAME $BO_LABEL, $API_LABEL"
if [[ -n "$CF_API_TOKEN" ]]; then
  for d in "$DOMAIN_BO" "$DOMAIN_API"; do cf_delete_cname "$d" && ok "ลบ CNAME $d" || skip "ไม่มี CNAME $d"; done
  ACCT=$(cf_account_id); TID=""; [[ -n "$ACCT" ]] && TID=$(cf_tunnel_id "$ACCT")
  if [[ -n "$TID" ]]; then
    cf_tunnel_delete "$ACCT" "$TID" && ok "ลบ tunnel $TID" || warn "ลบ tunnel $TID ไม่ได้ (ดู error ด้านบน) ลบเองที่ Zero Trust › Networks › Tunnels"
  else
    skip "ไม่มี tunnel แล้ว"
  fi
else
  warn "ลบเองที่ Zero Trust › Networks › Tunnels: $TUNNEL_NAME (CNAME $BO_LABEL, $API_LABEL จะถูกลบตาม)"
fi

# ---- 12) ไฟล์ในเครื่อง ----
step "12) ลบไฟล์ที่สคริปต์สร้าง"
rm -f .db_password .cf_tunnel_token .s3_access_key kubeconfig
ok ".db_password .cf_tunnel_token .s3_access_key kubeconfig (ไม่แตะ $SECRETS_FILE / .cf_token)"

echo
if [[ ${#WARNINGS[@]} -eq 0 ]]; then
  echo "ลบครบแล้ว"
else
  echo "เสร็จแต่มีสิ่งที่ต้องดูเอง:"; for w in "${WARNINGS[@]}"; do echo "  ⚠ $w"; done
fi
[[ ${#WARNINGS[@]} -eq 0 ]]
