#!/bin/bash
# ตรวจ PROD ทุกชั้น: EC2/k3s → cloudflared/tunnel → api/bo/HPA → ผ่าน Cloudflare ทั้ง 2 โดเมน → RDS → S3/secret   ทุกข้อ ✔ = ครบ
source "$(dirname "$0")/common.sh"
need_tools aws kubectl curl jq; need_kubeconfig; need_api

PASS=0; FAIL=0
check() { local msg=$1; shift; if "$@" > /dev/null 2>&1; then ok "$msg"; PASS=$((PASS + 1)); else echo "  ✘ $msg"; FAIL=$((FAIL + 1)); fi; }
WANT_NODES=$((1 + AGENT_COUNT))

echo "[1] EC2 + k3s"
ID=$(server_id)
AGENTS=$(instance_ids agent | wc -w | tr -d ' ')
instance_running() { [[ "$(aws ec2 describe-instances --instance-ids "$ID" --query "Reservations[0].Instances[0].State.Name" --output text)" == "running" ]]; }
nodes_ready()      { [[ $(kubectl get nodes --no-headers | grep -c ' Ready') -ge $WANT_NODES ]] && ! kubectl get nodes --no-headers | grep -q NotReady; }
check "instance $LAB_NAME-server มีอยู่" [ -n "$ID" ]
check "server running" instance_running
check "SSM Online (connect_k8s/connect_rds ใช้ได้)" ssm_online "$ID"
check "agent ครบ $AGENT_COUNT เครื่อง (มี $AGENTS)" [ "$AGENTS" -ge "$AGENT_COUNT" ]
check "node Ready ครบ $WANT_NODES ($(kubectl get nodes --no-headers 2> /dev/null | grep -c ' Ready' | tr -d ' ') node)" nodes_ready
check "metrics-server พร้อม (HPA ต้องใช้)" kubectl top nodes

echo "[2] cloudflared / tunnel"
cf_pods() { [[ $(kubectl get pods -l app=cloudflared --field-selector=status.phase=Running --no-headers | wc -l) -ge 1 ]]; }
check "pod cloudflared Running (>= 1 จาก $CLOUDFLARED_REPLICAS)" cf_pods
if [[ -n "$CF_API_TOKEN" ]]; then
  tunnel_healthy() { local a t; a=$(cf_account_id); t=$(cf_tunnel_id "$a"); [[ -n "$t" && "$(cf_tunnel_status "$a" "$t")" == "healthy" ]]; }
  check "tunnel $TUNNEL_NAME status = healthy" tunnel_healthy
else
  skip "ไม่มี CF_API_TOKEN ข้ามการเช็ก status ของ tunnel ผ่าน API"
fi

echo "[3] workload (tag $APP_TAG)"
pods_running() { [[ $(kubectl get pods -l "app=$1" --field-selector=status.phase=Running --no-headers | wc -l) -ge 2 ]]; }
hpa_metrics()  { [[ -n "$(kubectl get hpa "$1" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')" ]]; }
image_tag()    { kubectl get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q ":$APP_TAG\$"; }
for d in api bo; do
  check "pod $d Running (>= 2)" pods_running "$d"
  check "deploy $d ใช้ tag $APP_TAG" image_tag "$d"
  check "HPA $d อ่าน CPU ได้" hpa_metrics "$d"
done
check "Job migrate ล่าสุดสำเร็จ (หรือไม่มี)" bash -c "! kubectl get job migrate > /dev/null 2>&1 || kubectl get job migrate -o jsonpath='{.status.succeeded}' | grep -q 1"

echo "[4] Cloudflare"
code()     { curl -sSL -o /dev/null -w '%{http_code}' --max-time 10 "$1"; }
via_edge() { curl -sSI --max-time 10 "$1" | grep -qi '^cf-ray:'; }
check "https://$DOMAIN_API$API_HEALTH_PATH = 200" [ "$(code "https://$DOMAIN_API$API_HEALTH_PATH")" = 200 ]
check "https://$DOMAIN_BO = 200" [ "$(code "https://$DOMAIN_BO/")" = 200 ]
check "response มี header cf-ray (มาจาก Cloudflare edge)" via_edge "https://$DOMAIN_API$API_HEALTH_PATH"

echo "[5] RDS"
rds_q() { aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query "DBInstances[0].$1" --output text; }
pod_psql() {   # pod ชั่วคราว (postgres client) ใช้ env จาก secret เดียวกับที่ api ได้รับ ต่อ RDS แล้วลบตัวเอง
  kubectl delete pod psql-check --ignore-not-found > /dev/null 2>&1
  kubectl run psql-check --rm -i --restart=Never --image=postgres:16-alpine --pod-running-timeout=120s \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"psql-check\",\"image\":\"postgres:16-alpine\",\"envFrom\":[{\"secretRef\":{\"name\":\"$K8S_SECRET\"}}],\"command\":[\"sh\",\"-c\",\"PGPASSWORD=\$DB_PASSWORD timeout 15 psql -h \$DB_HOST -U \$DB_USER -d \$DB_NAME -tAc 'SELECT 1'\"]}]}}" \
    2> /dev/null | grep -qx 1
}
check "instance available" [ "$(rds_q DBInstanceStatus)" = available ]
check "Multi-AZ" [ "$(rds_q MultiAZ)" = True ]
check "deletion protection" [ "$(rds_q DeletionProtection)" = True ]
check "backup retention $DB_BACKUP_DAYS วัน" [ "$(rds_q BackupRetentionPeriod)" = "$DB_BACKUP_DAYS" ]
check "secret $K8S_SECRET มี POSTGRES_PRISMA_URL" bash -c "kubectl get secret $K8S_SECRET -o jsonpath='{.data.POSTGRES_PRISMA_URL}' | grep -q ."
check "pod เชื่อมต่อ PostgreSQL ได้" pod_psql

echo "[6] S3 + secret ของแอป"
BUCKET=$(s3_bucket)
check "bucket $BUCKET มีอยู่" aws s3api head-bucket --bucket "$BUCKET"
check "bucket เปิด versioning" bash -c "aws s3api get-bucket-versioning --bucket $BUCKET --query Status --output text | grep -q Enabled"
check "secret $APP_SECRET มี AWS_ACCESS_KEY_ID" bash -c "kubectl get secret $APP_SECRET -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | grep -q ."
check "secret $TUNNEL_SECRET มีอยู่" kubectl get secret "$TUNNEL_SECRET"

echo
echo "ผ่าน $PASS / ไม่ผ่าน $FAIL"
[[ $FAIL -eq 0 ]]
