#!/bin/bash
# ขั้น 2: RDS PostgreSQL ของ PROD (Multi-AZ, encrypted, backup DB_BACKUP_DAYS วัน, deletion protection, storage autoscaling)
#         ใน subnet ของ environment (ไม่มี public IP รับ 5432 จาก SG ของ node เท่านั้น) แล้วส่ง credential + POSTGRES_PRISMA_URL ให้ pod ผ่าน secret
#         ถ้าตั้ง ALARM_EMAIL จะสร้าง SNS topic + CloudWatch alarm (CPU / พื้นที่ว่าง / memory) ด้วย
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl openssl; need_aws; need_kubeconfig; need_api   # ขั้นนี้เขียน secret เข้า cluster จึงต้องมี tunnel เปิดอยู่

VPC_ID=$(lab_vpc); [[ -n "$VPC_ID" ]] || die "ไม่พบ VPC $LAB_NAME รัน ./1_create_cluster.sh ก่อน"
NODE_SG_ID=$(sg_id "$NODE_SG"); [[ -n "$NODE_SG_ID" ]] || die "ไม่พบ security group $NODE_SG รัน ./1_create_cluster.sh ก่อน"
echo "VPC: $VPC_ID | Node SG: $NODE_SG_ID"

step "1) DB subnet group $SUBNET_GROUP (subnet ทั้ง 2 AZ: Multi-AZ ต้องมี standby อีก AZ)"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP" > /dev/null 2>&1; then
  skip "มีอยู่แล้ว"
else
  SUBNETS=$(lab_subnets)
  aws rds create-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" \
    --db-subnet-group-description "$LAB_NAME subnets" --subnet-ids $SUBNETS --tags "Key=lab,Value=$LAB_NAME" > /dev/null
  ok "สร้างแล้ว: $SUBNETS"
fi

step "2) security group $SG_NAME (รับ 5432 จาก $NODE_SG เท่านั้น)"
RDS_SG=$(sg_id "$SG_NAME")
if [[ -n "$RDS_SG" ]]; then
  skip "มีอยู่แล้ว: $RDS_SG"
else
  RDS_SG=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Allow Postgres from k3s nodes ($LAB_NAME)" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tags security-group "$SG_NAME")" --query GroupId --output text)
  ok "สร้างแล้ว: $RDS_SG"
fi
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" --protocol tcp --port 5432 --source-group "$NODE_SG_ID" > /dev/null 2>&1 \
  && ok "เพิ่ม ingress rule" || skip "ingress rule มีอยู่แล้ว"

step "3) รหัสผ่าน master"
if [[ -s .db_password ]]; then
  DB_PASSWORD=$(< .db_password)
  skip "ใช้รหัสเดิมจาก .db_password"
elif kubectl get secret "$K8S_SECRET" > /dev/null 2>&1; then   # ไฟล์หายแต่ secret ยังอยู่ → กู้ ไม่สุ่มใหม่ (รหัสใหม่จะไม่ตรงกับ RDS)
  DB_PASSWORD=$(kubectl get secret "$K8S_SECRET" -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)
  printf '%s' "$DB_PASSWORD" > .db_password && chmod 600 .db_password
  ok "กู้ .db_password จาก secret $K8S_SECRET"
else
  DB_PASSWORD=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 24)   # เฉพาะ a-z A-Z 0-9 เพื่อใส่ใน URL ของ Prisma ได้ตรงๆ
  printf '%s' "$DB_PASSWORD" > .db_password
  chmod 600 .db_password
  ok "สุ่มรหัสใหม่ เก็บไว้ที่ .db_password"
fi

step "4) RDS $DB_ID (postgres $DB_ENGINE_VERSION, $DB_CLASS, Multi-AZ, ${DB_STORAGE_GB}→${DB_MAX_STORAGE_GB} GB gp3, backup $DB_BACKUP_DAYS วัน)"
if [[ "$(rds_status)" != "none" ]]; then
  skip "มีอยู่แล้ว ข้ามการสร้าง"
else
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --engine postgres --engine-version "$DB_ENGINE_VERSION" \
    --db-instance-class "$DB_CLASS" \
    --allocated-storage "$DB_STORAGE_GB" --max-allocated-storage "$DB_MAX_STORAGE_GB" \
    --storage-type gp3 --storage-encrypted \
    --db-name "$DB_NAME" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$RDS_SG" \
    --no-publicly-accessible \
    --multi-az \
    --backup-retention-period "$DB_BACKUP_DAYS" \
    --copy-tags-to-snapshot \
    --deletion-protection \
    --auto-minor-version-upgrade \
    --tags "Key=lab,Value=$LAB_NAME" \
    --no-cli-pager > /dev/null
  ok "สั่งสร้างแล้ว"
fi
echo "  รอ RDS พร้อมใช้งาน (Multi-AZ ใช้เวลา 15-20 นาที)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
DB_HOST=$(rds_endpoint)
ok "Endpoint: $DB_HOST"

step "5) Kubernetes secret $K8S_SECRET (DB_* + POSTGRES_PRISMA_URL connection_limit=$DB_POOL_PER_POD ต่อ pod)"
PRISMA_URL="postgresql://$DB_USER:$DB_PASSWORD@$DB_HOST:5432/$DB_NAME?schema=public&connection_limit=$DB_POOL_PER_POD"
kubectl create secret generic "$K8S_SECRET" \
  --from-literal=DB_HOST="$DB_HOST" \
  --from-literal=DB_PORT=5432 \
  --from-literal=DB_NAME="$DB_NAME" \
  --from-literal=DB_USER="$DB_USER" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=POSTGRES_PRISMA_URL="$PRISMA_URL" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null
ok "secret พร้อม"

step "6) CloudWatch alarm → email"
if [[ -z "$ALARM_EMAIL" ]]; then
  skip "ไม่ได้ตั้ง ALARM_EMAIL ใน .env ข้าม (ตั้งแล้วรันขั้นนี้ซ้ำได้)"
else
  TOPIC=$(aws sns create-topic --name "$LAB_NAME-alarms" --tags "Key=lab,Value=$LAB_NAME" --query TopicArn --output text)   # idempotent ตามชื่อ
  if aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --query "Subscriptions[?Endpoint=='$ALARM_EMAIL']" --output text | grep -q .; then
    skip "subscribe $ALARM_EMAIL ไว้แล้ว"
  else
    aws sns subscribe --topic-arn "$TOPIC" --protocol email --notification-endpoint "$ALARM_EMAIL" > /dev/null
    ok "ส่ง email ยืนยันไปที่ $ALARM_EMAIL แล้ว (กด Confirm ในเมล ไม่งั้น alarm ไม่ถึง)"
  fi
  alarm() {   # alarm <ชื่อ> <metric> <เปรียบเทียบ> <threshold> <คำอธิบาย>
    aws cloudwatch put-metric-alarm --alarm-name "$LAB_NAME-rds-$1" --alarm-description "$5" \
      --namespace AWS/RDS --metric-name "$2" --dimensions "Name=DBInstanceIdentifier,Value=$DB_ID" \
      --statistic Average --period 300 --evaluation-periods 3 --comparison-operator "$3" --threshold "$4" \
      --treat-missing-data notBreaching --alarm-actions "$TOPIC" --ok-actions "$TOPIC" --tags "Key=lab,Value=$LAB_NAME"
    ok "alarm $LAB_NAME-rds-$1 ($2 $3 $4)"
  }
  alarm cpu     CPUUtilization   GreaterThanThreshold 80         "RDS $DB_ID CPU > 80% 15 นาที"
  alarm storage FreeStorageSpace LessThanThreshold    5368709120 "RDS $DB_ID พื้นที่ว่าง < 5 GiB"
  alarm memory  FreeableMemory   LessThanThreshold    209715200  "RDS $DB_ID memory ว่าง < 200 MiB"
fi

echo
echo "ต่อ DB จากเครื่อง: ./connect_rds.sh"
echo "ถัดไป: ./3_create_tunnel.sh"
