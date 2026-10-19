#!/bin/bash
# เครื่องมือเสริม: เปิด tunnel ไป RDS ผ่าน SSM บนเครื่อง k3s server แล้วต่อจากเครื่องด้วย DBeaver/psql/pg_dump ที่ localhost:$LOCAL_PORT
# ใช้: ./connect_rds.sh                (ค้างไว้จนกด Ctrl+C)
#      LOCAL_PORT=5433 ./connect_rds.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl session-manager-plugin; need_aws

if [[ -s .db_password ]]; then
  DB_PASSWORD=$(< .db_password)
else   # ไฟล์หาย กู้จาก secret ใน cluster (ต้องมี tunnel k8s เปิดอยู่)
  need_kubeconfig; need_api
  DB_PASSWORD=$(kubectl get secret "$K8S_SECRET" -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)
  printf '%s' "$DB_PASSWORD" > .db_password && chmod 600 .db_password
  ok "กู้ .db_password จาก secret $K8S_SECRET แล้ว"
fi
DB_HOST=$(rds_endpoint)

NODE=$(server_id); [[ -n "$NODE" ]] || die "ไม่พบ instance $LAB_NAME-server รัน ./1_create_cluster.sh ก่อน"
ssm_online "$NODE" || die "instance $NODE ยังไม่ Online ใน SSM (รอ 1-2 นาทีหลังเครื่องขึ้น)"

cat <<EOT
Node : $NODE
RDS  : $DB_HOST
Local: localhost:$LOCAL_PORT

DBeaver → PostgreSQL
  Host     : localhost
  Port     : $LOCAL_PORT
  Database : $DB_NAME
  Username : $DB_USER
  Password : $DB_PASSWORD

psql:    PGPASSWORD='$DB_PASSWORD' psql -h localhost -p $LOCAL_PORT -U $DB_USER -d $DB_NAME
pg_dump: PGPASSWORD='$DB_PASSWORD' pg_dump -h localhost -p $LOCAL_PORT -U $DB_USER -d $DB_NAME -Fc -f $DB_NAME-\$(date +%Y%m%d).dump
กด Ctrl+C เพื่อปิด tunnel

EOT
aws ssm start-session \
  --target "$NODE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$DB_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
