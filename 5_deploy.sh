#!/bin/bash
# ขั้น 5 / ขึ้นเวอร์ชันใหม่: snapshot RDS → Job migrate (prisma migrate deploy ด้วย image ใหม่) → apply k8s/*.yaml → rollout → เช็ก https ทั้ง 2 โดเมน
# ใช้: APP_TAG=v1.2.3 ./5_deploy.sh        (ไม่ใส่ = APP_TAG ใน .env)
#      SKIP_SNAPSHOT=1 ./5_deploy.sh      ข้าม snapshot (เช่น deploy ซ้ำ tag เดิม)
#      SKIP_MIGRATE=1 ./5_deploy.sh       ข้าม Job migrate
# ย้อนกลับ: ./rollback.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl curl; need_aws; need_kubeconfig; need_api
SKIP_SNAPSHOT=${SKIP_SNAPSHOT:-0}; SKIP_MIGRATE=${SKIP_MIGRATE:-0}

step "1) ตรวจ secret ที่ manifest อ้างถึง"
kubectl get secret "$K8S_SECRET" > /dev/null 2>&1    || die "ไม่พบ secret $K8S_SECRET รัน ./2_create_rds.sh ก่อน"
kubectl get secret "$TUNNEL_SECRET" > /dev/null 2>&1 || die "ไม่พบ secret $TUNNEL_SECRET รัน ./3_create_tunnel.sh ก่อน"
kubectl get secret "$APP_SECRET" > /dev/null 2>&1    || die "ไม่พบ secret $APP_SECRET รัน ./4_create_secrets.sh ก่อน"
ok "$K8S_SECRET, $TUNNEL_SECRET, $APP_SECRET"
[[ "$APP_TAG" == "latest" ]] && echo "  (ใช้ tag latest: PROD ควรระบุ tag ชัดเจน เช่น APP_TAG=v1.2.3 เพื่อให้ rollback/ตรวจสอบย้อนหลังได้)"

step "2) snapshot RDS ก่อน migrate"
if [[ "$SKIP_SNAPSHOT" == 1 ]]; then
  skip "SKIP_SNAPSHOT=1"
elif [[ "$(rds_status)" != "available" ]]; then
  warn "RDS $DB_ID ไม่อยู่ในสถานะ available ($(rds_status)) ข้าม snapshot"
else
  SNAP=$(snapshot_id "pre-$APP_TAG")
  aws rds create-db-snapshot --db-instance-identifier "$DB_ID" --db-snapshot-identifier "$SNAP" --tags "Key=lab,Value=$LAB_NAME" --no-cli-pager > /dev/null \
    && ok "สั่งสร้าง $SNAP (ถ่ายจาก standby ของ Multi-AZ ไม่กระทบ primary ไม่ต้องรอเสร็จ)" || die "สร้าง snapshot ไม่สำเร็จ"
fi

step "3) Job migrate ($API_IMAGE:$APP_TAG: $MIGRATE_CMD)"
if [[ "$SKIP_MIGRATE" == 1 ]]; then
  skip "SKIP_MIGRATE=1"
else
  kubectl delete job migrate --ignore-not-found --wait=true > /dev/null
  render k8s/migrate-job.yaml | kubectl apply -f - > /dev/null
  if kubectl wait --for=condition=complete job/migrate --timeout=300s > /dev/null 2>&1; then
    ok "migrate สำเร็จ"
  else
    echo; kubectl logs job/migrate --tail=50 2> /dev/null || true; echo
    die "Job migrate ไม่สำเร็จ หยุด release (pod เวอร์ชันเดิมยังรันอยู่) ถ้า DB เปลี่ยนไปแล้วให้ restore จาก snapshot ${SNAP:-ล่าสุด}"
  fi
fi

step "4) apply k8s/ (api, bo, cloudflared) tag $APP_TAG"
for f in k8s/api.yaml k8s/bo.yaml k8s/cloudflared.yaml; do render "$f" | kubectl apply -f - | sed 's/^/    /'; done
kubectl rollout status deployment/api --timeout=180s || die "api rollout ไม่สำเร็จ ดู: ./logs.sh api  แล้ว ./rollback.sh"
kubectl rollout status deployment/bo  --timeout=180s || die "bo rollout ไม่สำเร็จ ดู: ./logs.sh bo  แล้ว ./rollback.sh"
kubectl rollout status deployment/cloudflared --timeout=180s \
  || die "cloudflared ไม่พร้อม ดู: ./logs.sh cloudflared (token ผิด/หมดอายุ หรือ tunnel ถูกลบ)"
ok "rollout ครบ"

step "5) ผ่าน Cloudflare → tunnel → pod"
code() { curl -sSL -o /dev/null -w '%{http_code}' --max-time 10 "$1"; }
api_ok() { [[ "$(code "https://$DOMAIN_API$API_HEALTH_PATH")" == "200" ]]; }
bo_ok()  { [[ "$(code "https://$DOMAIN_BO/")" == "200" ]]; }
if wait_for "DNS และ tunnel พร้อม" 10 18 api_ok; then ok "https://$DOMAIN_API$API_HEALTH_PATH = 200"; else
  NOTE="ยังไม่ได้ 200 จาก https://$DOMAIN_API$API_HEALTH_PATH ดู: ./logs.sh cloudflared และ ./logs.sh api"
  [[ -z "$CF_API_TOKEN" ]] && NOTE="$NOTE และเช็ก Public Hostname ใน Zero Trust"
  warn "$NOTE"
fi
if bo_ok; then ok "https://$DOMAIN_BO = 200"; else warn "https://$DOMAIN_BO ยังไม่ได้ 200 (code $(code "https://$DOMAIN_BO/")) ดู: ./logs.sh bo"; fi

echo
echo "ตรวจทุกชั้น: ./verify.sh     ย้อนกลับ: ./rollback.sh     log: ./logs.sh api|bo|cloudflared"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo; echo "เสร็จแต่มีสิ่งที่ต้องดูเอง:"; for w in "${WARNINGS[@]}"; do echo "  ⚠ $w"; done
fi
[[ ${#WARNINGS[@]} -eq 0 ]]
