#!/bin/bash
# ขั้น 4: ของที่แอปต้องใช้นอกเหนือจาก DB: S3 bucket (versioning + lifecycle, block public) + IAM user สิทธิ์เฉพาะ bucket + access key
#         แล้วรวมกับ app-secrets.env (JWT/SMTP/Maps ที่ผู้ใช้กรอก) เป็น k8s secret app-secrets ให้ pod api/bo อ่านเป็น env
# รันซ้ำได้: ใช้ access key เดิมจาก .s3_access_key, secret ถูก apply ทับ (เปลี่ยนค่าแล้วต้อง kubectl rollout restart deploy/api deploy/bo หรือ ./5_deploy.sh)
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl jq; need_aws; need_kubeconfig; need_api

BUCKET=$(s3_bucket)

step "0) ไฟล์ $SECRETS_FILE"
[[ -s "$SECRETS_FILE" ]] || die "ไม่พบ $SECRETS_FILE: cp app-secrets.env.example $SECRETS_FILE แล้วใส่ค่าจริงก่อน"
if grep -q 'CHANGE_ME' "$SECRETS_FILE"; then
  grep -n 'CHANGE_ME' "$SECRETS_FILE" | sed 's/=.*//' | sed 's/^/    /'
  die "ยังมีค่า CHANGE_ME ใน $SECRETS_FILE (บรรทัดด้านบน)"
fi
ok "พบ $(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_FILE") ค่า"

step "1) S3 bucket $BUCKET (block public, SSE-S3, versioning, ลบ version เก่าหลัง $S3_NONCURRENT_DAYS วัน)"
if aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
  skip "มีอยู่แล้ว"
else
  aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" > /dev/null
  ok "สร้างแล้ว"
fi
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration "$(jq -n --argjson d "$S3_NONCURRENT_DAYS" '{Rules:[
  {ID:"expire-noncurrent", Status:"Enabled", Filter:{}, NoncurrentVersionExpiration:{NoncurrentDays:$d}},
  {ID:"abort-multipart",   Status:"Enabled", Filter:{}, AbortIncompleteMultipartUpload:{DaysAfterInitiation:7}}]}')"
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=lab,Value=$LAB_NAME}]"
ok "ตั้งค่า bucket แล้ว (idempotent)"

step "2) IAM user $S3_USER (สิทธิ์เฉพาะ bucket นี้ ไม่มี console)"
if aws iam get-user --user-name "$S3_USER" > /dev/null 2>&1; then
  skip "มีอยู่แล้ว"
else
  aws iam create-user --user-name "$S3_USER" --tags "Key=lab,Value=$LAB_NAME" > /dev/null
  ok "สร้างแล้ว"
fi
aws iam put-user-policy --user-name "$S3_USER" --policy-name "$S3_USER-policy" --policy-document "$(jq -n --arg b "$BUCKET" '{Version:"2012-10-17", Statement:[
  {Effect:"Allow", Action:["s3:ListBucket","s3:GetBucketLocation"], Resource:("arn:aws:s3:::"+$b)},
  {Effect:"Allow", Action:["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload"], Resource:("arn:aws:s3:::"+$b+"/*")}]}')"
ok "policy $S3_USER-policy (List bucket + Get/Put/Delete object)"

step "3) access key (เก็บใน .s3_access_key)"
if [[ -s .s3_access_key ]]; then
  AK=$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' .s3_access_key); SK=$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' .s3_access_key)
  if aws iam list-access-keys --user-name "$S3_USER" --query "AccessKeyMetadata[?AccessKeyId=='$AK' && Status=='Active']" --output text | grep -q .; then
    skip "ใช้ key เดิม $AK"
  else
    die "key $AK ใน .s3_access_key ไม่มีใน IAM แล้ว ลบไฟล์ .s3_access_key แล้วรันใหม่เพื่อออก key ใหม่"
  fi
else
  N=$(aws iam list-access-keys --user-name "$S3_USER" --query "length(AccessKeyMetadata)" --output text)
  [[ "$N" -lt 2 ]] || die "user $S3_USER มี access key ครบ 2 ตัวแล้ว ลบตัวที่ไม่ใช้ก่อน: aws iam delete-access-key --user-name $S3_USER --access-key-id <id>"
  KEY=$(aws iam create-access-key --user-name "$S3_USER" --query AccessKey --output json)
  AK=$(jq -r .AccessKeyId <<< "$KEY"); SK=$(jq -r .SecretAccessKey <<< "$KEY")
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$AK" "$SK" > .s3_access_key && chmod 600 .s3_access_key
  ok "ออก key ใหม่ $AK"
fi

step "4) Kubernetes secret $APP_SECRET ($SECRETS_FILE + ค่าที่ generate)"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_FILE" > "$TMP"   # ตัด comment/บรรทัดว่าง (--from-env-file รับ KEY=value เท่านั้น)
add_if_missing() { grep -q "^$1=" "$TMP" || echo "$1=$2" >> "$TMP"; }   # ค่าในไฟล์ของผู้ใช้ชนะค่าที่ generate
add_if_missing AWS_REGION            "$AWS_REGION"
add_if_missing AWS_ACCESS_KEY_ID     "$AK"
add_if_missing AWS_SECRET_ACCESS_KEY "$SK"
add_if_missing AWS_S3_BUCKET         "$BUCKET"
add_if_missing CORS_ALLOWED_ORIGINS  "https://$DOMAIN_BO"
kubectl create secret generic "$APP_SECRET" --from-env-file="$TMP" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
ok "secret $APP_SECRET มี $(wc -l < "$TMP" | tr -d ' ') key: $(cut -d= -f1 "$TMP" | tr '\n' ' ')"

echo
echo "ถัดไป: APP_TAG=<tag> ./5_deploy.sh"
