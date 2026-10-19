#!/bin/bash
# เครื่องมือเสริม: ย้อน api + bo กลับ revision ก่อนหน้า (image เก่ายังอยู่บน Docker Hub) แล้วรอ rollout
# ใช้: ./rollback.sh            ย้อนทั้ง api และ bo
#      ./rollback.sh api        ย้อนเฉพาะ api
# ถ้า migration เปลี่ยน schema จน code เก่าใช้ไม่ได้ ต้อง restore DB จาก snapshot pre-<tag> ที่ 5_deploy.sh ถ่ายไว้ด้วย (ดูคำสั่งท้ายสคริปต์)
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl; need_kubeconfig; need_api
TARGETS=${1:-"api bo"}

for d in $TARGETS; do
  step "rollback deploy/$d"
  echo "  ก่อน: $(kubectl get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  kubectl rollout undo "deploy/$d"
  kubectl rollout status "deploy/$d" --timeout=180s || die "$d rollout ไม่สำเร็จ ดู: ./logs.sh $d"
  ok "หลัง: $(kubectl get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}')"
done

echo
echo "snapshot ของ $DB_ID ล่าสุด (ถ้าต้อง restore DB):"
aws rds describe-db-snapshots --db-instance-identifier "$DB_ID" --snapshot-type manual \
  --query "reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[:5].[DBSnapshotIdentifier,Status,SnapshotCreateTime]" --output table 2> /dev/null || true
cat <<EOT
restore = สร้าง instance ใหม่จาก snapshot แล้วสลับ endpoint (RDS restore ทับตัวเดิมไม่ได้):
  aws rds restore-db-instance-from-db-snapshot --db-instance-identifier $DB_ID-restore --db-snapshot-identifier <snapshot> \\
    --db-instance-class $DB_CLASS --db-subnet-group-name $SUBNET_GROUP --vpc-security-group-ids \$(source common.sh; sg_id $SG_NAME) --multi-az --no-publicly-accessible
  แล้วแก้ DB_HOST/POSTGRES_PRISMA_URL ใน secret $K8S_SECRET (หรือ rename instance ให้เป็น $DB_ID) และ kubectl rollout restart deploy/api
EOT
