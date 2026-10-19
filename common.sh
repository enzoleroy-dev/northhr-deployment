#!/bin/bash
# โหลด .env และรวมสิ่งที่ทุกสคริปต์ใช้ร่วมกัน: แสดงผล, ตรวจก่อนเริ่ม, lookup, EC2/SSM, k3s agent, manifest, S3, RDS snapshot, Cloudflare (DNS + Tunnel)
# ทุกสคริปต์เรียกบรรทัดแรกหลัง set: source "$(dirname "$0")/common.sh"
# ต่อยอดจาก ../aws-ec2-k3s-cloudflared-app-rds-lab/common.sh (โครงเดียวกัน) ส่วนที่ต่างคือ 2 โดเมน, หลาย instance type, secret ของแอป, S3

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$LAB_DIR"   # ให้ .env .db_password kubeconfig k8s/ อ้างแบบ relative ได้ ไม่ว่ารันจากที่ไหน

set -a; source .env; set +a   # ทุกบรรทัดใน .env เป็น VAR=${VAR:-ค่า} ค่าที่ export ใน shell จึงชนะ
export AWS_REGION
export AWS_PROFILE=${AWS_PROFILE:-$LAB_PROFILE}
[[ -z "$AWS_PROFILE" ]] && unset AWS_PROFILE
[[ -z "$CF_API_TOKEN" && -s .cf_token ]] && CF_API_TOKEN=$(< .cf_token)
export KUBECONFIG="$LAB_DIR/kubeconfig"   # kubectl ทุกครั้งใช้ไฟล์นี้ (ขั้น 1 ดึงมาจากเครื่อง) ไม่แตะ ~/.kube/config

# ชื่อ Service/Deployment ใน cluster (namespace default) ตรงกับ k8s/*.yaml และปลายทางของ tunnel
API_SVC=api
BO_SVC=bo
API_TARGET="http://$API_SVC.default.svc.cluster.local:$API_PORT"   # DOMAIN_API → hr-api
BO_TARGET="http://$BO_SVC.default.svc.cluster.local:$BO_PORT"      # DOMAIN_BO  → hr-bo
BO_LABEL=${DOMAIN_BO%.$ZONE}     # ชื่อ record ใน Cloudflare เช่น hr
API_LABEL=${DOMAIN_API%.$ZONE}   # เช่น api.hr

# ---------- แสดงผล ----------
WARNINGS=()
step() { echo; echo "▶ $*"; }
ok()   { echo "  ✔ $*"; }
skip() { echo "  – $*"; }
warn() { echo "  ⚠ $*"; WARNINGS+=("$*"); }
die()  { echo "✘ $*" >&2; exit 1; }

# ---------- ตรวจก่อนเริ่ม ----------
need_tools()      { local t; for t in "$@"; do command -v "$t" > /dev/null || die "ไม่พบคำสั่ง $t"; done; }
need_aws()        { aws sts get-caller-identity > /dev/null 2>&1 || die "aws credentials ใช้ไม่ได้ รัน: aws sso login --profile ${AWS_PROFILE:-<profile>}"; }
need_kubeconfig() { [[ -s kubeconfig ]] || die "ไม่พบ ./kubeconfig รัน ./1_create_cluster.sh ก่อน"; }

# ---------- k3s API ผ่าน SSM tunnel ----------
# SG ไม่เปิด 6443 ออกอินเทอร์เน็ตเลย: kubectl/Lens ต่อที่ 127.0.0.1:$K8S_LOCAL_PORT แล้ว SSM ส่งต่อไป 6443 บนเครื่อง server
# เปิด tunnel ค้างไว้อีก terminal ด้วย ./connect_k8s.sh
API_LOCAL="127.0.0.1:$K8S_LOCAL_PORT"
api_up()   { (exec 3<> "/dev/tcp/127.0.0.1/$K8S_LOCAL_PORT") > /dev/null 2>&1; }
need_api() { api_up || die "ยังไม่มี tunnel ที่ $API_LOCAL เปิดอีก terminal แล้วรัน $LAB_DIR/connect_k8s.sh ค้างไว้ก่อน"; }
api_set_kubeconfig() {   # ให้บรรทัด server: ใน ./kubeconfig ตรงกับพอร์ตของ tunnel (เรียกซ้ำได้)
  grep -q "server: https://$API_LOCAL\$" kubeconfig && return 0
  sed -i.bak -E "s|server: https://[^[:space:]]+|server: https://$API_LOCAL|" kubeconfig
  rm -f kubeconfig.bak; chmod 600 kubeconfig
  ok "แก้ server ใน kubeconfig เป็น https://$API_LOCAL"
}

# ---------- lookup ที่หลายสคริปต์ใช้ (ค้นจาก tag lab=$LAB_NAME ไม่เก็บ id ไว้ในไฟล์) ----------
account_id()  { aws sts get-caller-identity --query Account --output text; }
lab_vpc()     { aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$LAB_NAME" --query "Vpcs[0].VpcId" --output text | sed '/^None$/d'; }
lab_subnets() { aws ec2 describe-subnets --filters "Name=tag:lab,Values=$LAB_NAME" --query "Subnets[].SubnetId" --output text; }
sg_id()       {   # sg_id <group-name>  (ว่างถ้าไม่มี)
  aws ec2 describe-security-groups --filters "Name=tag:lab,Values=$LAB_NAME" "Name=group-name,Values=$1" \
    --query "SecurityGroups[0].GroupId" --output text 2> /dev/null | sed '/^None$/d'
}
instance_ids() {   # instance_ids <server|agent>  id ของ instance ที่ยังไม่ terminated (agent มีหลายตัว)
  aws ec2 describe-instances --filters "Name=tag:lab,Values=$LAB_NAME" "Name=tag:role,Values=$1" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text
}
server_id()         { instance_ids server | awk '{print $1}'; }
server_ip()         { aws ec2 describe-addresses --filters "Name=tag:Name,Values=$LAB_NAME" --query "Addresses[0].PublicIp" --output text | sed '/^None$/d'; }   # Elastic IP
server_private_ip() { aws ec2 describe-instances --instance-ids "$(server_id)" --query "Reservations[0].Instances[0].PrivateIpAddress" --output text; }
rds_endpoint()      { aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query DBInstances[0].Endpoint.Address --output text; }
rds_status()        { aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query DBInstances[0].DBInstanceStatus --output text 2> /dev/null || echo none; }
s3_bucket()         { echo "${S3_BUCKET:-$LAB_NAME-files-$(account_id)}"; }   # ชื่อ bucket (ต้องไม่ซ้ำทั้งโลก จึงต่อ account id)
lab_ami() {   # lab_ami <instance-type>  AMI Amazon Linux 2023 ล่าสุด ตาม arch ของ instance type (arm64 / x86_64)
  local arch
  arch=$(aws ec2 describe-instance-types --instance-types "$1" --query "InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]" --output text)
  aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$arch" --query Parameter.Value --output text
}
tags() {   # tags <resource-type> <Name> [role]  → --tag-specifications ที่ติด Name + lab (+ role)
  local t="ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=lab,Value=$LAB_NAME}"
  [[ -n "${3:-}" ]] && t="$t,{Key=role,Value=$3}"
  echo "$t]"
}

# ---------- EC2 / SSM ----------
# launch_instance <Name> <role> <subnet-id> <user-data> <instance-type>   สร้าง instance แล้วพิมพ์ id (retry เผื่อ instance profile ยัง propagate ไม่ทัน)
launch_instance() {
  local name=$1 role=$2 subnet=$3 ud=$4 type=$5 ami out i
  ami=$(lab_ami "$type")
  for i in 1 2 3 4 5 6; do
    out=$(aws ec2 run-instances --image-id "$ami" --instance-type "$type" --subnet-id "$subnet" \
      --security-group-ids "$(sg_id "$NODE_SG")" --iam-instance-profile "Name=$ROLE_NAME" \
      --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,Encrypted=true}" \
      --metadata-options HttpTokens=required --user-data "$ud" \
      --tag-specifications "$(tags instance "$name" "$role")" \
      --query "Instances[0].InstanceId" --output text 2>&1) && { echo "$out"; return 0; }
    sleep 5
  done
  echo "$out" >&2
  return 1
}
ssm_online() { [[ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" --query "InstanceInformationList[0].PingStatus" --output text 2> /dev/null)" == "Online" ]]; }
ssm_run() {   # ssm_run <instance-id> "<คำสั่ง shell>"   รันบนเครื่องผ่าน SSM (เป็น root) พิมพ์ stdout; คืน 1 ถ้าคำสั่งล้ม
  local cid st
  cid=$(aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$2" '{commands:[$c]}')" --query Command.CommandId --output text) || return 1
  while :; do
    st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$1" --query Status --output text 2> /dev/null || echo Pending)
    case "$st" in Pending|InProgress|Delayed) sleep 2 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$1" --query StandardOutputContent --output text
  [[ "$st" == "Success" ]]
}
K3S=/usr/local/bin/k3s   # path เต็ม เพราะ PATH ของ SSM ไม่มี /usr/local/bin
nodes_ready_ssm() { ssm_run "$1" "$K3S kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'" 2> /dev/null | tr -dc '0-9'; }   # นับ node Ready โดยไม่ต้องมี tunnel

# ---------- k3s agent (ใช้ทั้งขั้น 1 และ add_node.sh) ----------
# launch_agents <N>   สร้าง agent N เครื่อง join server ด้วย node-token ที่อ่านผ่าน SSM แล้วรอจน node Ready ครบ (นับผ่าน SSM จึงไม่ต้องเปิด tunnel)
launch_agents() {
  local n=$1 server token priv existing before want ud idx subnet id subnets=()
  server=$(server_id); [[ -n "$server" ]] || die "ไม่พบ instance $LAB_NAME-server"
  read -ra subnets <<< "$(lab_subnets)"
  priv=$(server_private_ip)
  existing=$(instance_ids agent | wc -w | tr -d ' ')
  before=$(nodes_ready_ssm "$server"); before=${before:-0}
  token=$(ssm_run "$server" "cat /var/lib/rancher/k3s/server/node-token") || die "อ่าน node-token จาก server ไม่ได้"
  # agent ต่อ server ด้วย private IP ใน VPC (SG อนุญาต node ↔ node ทุกพอร์ต)
  ud=$(cat <<EOF
#!/bin/bash
curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true ${K3S_VERSION:+INSTALL_K3S_VERSION=$K3S_VERSION} \\
  K3S_URL=https://$priv:6443 K3S_TOKEN=$token sh -
EOF
)
  for ((idx = existing + 1; idx <= existing + n; idx++)); do
    subnet=${subnets[$((idx % ${#subnets[@]}))]}   # สลับ AZ: agent-1 → subnet ที่ 2 (คนละ AZ กับ server), agent-2 → subnet แรก
    id=$(launch_instance "$LAB_NAME-agent-$idx" agent "$subnet" "$ud" "$AGENT_TYPE") || die "run-instances ของ agent ไม่สำเร็จ"
    ok "$LAB_NAME-agent-$idx: $id ($AGENT_TYPE, $subnet)"
  done
  want=$((before + n))
  enough() { [[ "$(nodes_ready_ssm "$server")" -ge "$want" ]]; }
  wait_for "node Ready ครบ $want" 15 24 enough || die "agent ยังไม่ join ครบ ดู: aws ssm start-session --target <agent-id> แล้ว journalctl -u k3s-agent"
}

# wait_for "สิ่งที่รอ" <วินาทีต่อรอบ> <จำนวนรอบ> คำสั่ง...   รันคำสั่งซ้ำจนสำเร็จ คืน 1 ถ้าหมดรอบ
wait_for() {
  local what=$1 every=$2 tries=$3 i; shift 3
  for ((i = 1; i <= tries; i++)); do
    "$@" > /dev/null 2>&1 && return 0
    [[ $i -eq 1 ]] && echo "  รอ $what (สูงสุด $((every * tries / 60)) นาที)..."
    sleep "$every"
  done
  return 1
}

# ---------- manifest ----------
# render <ไฟล์ใน k8s/>  แทน placeholder ทุกตัวด้วยค่าจาก .env แล้วพิมพ์ออก stdout (ไฟล์ใน k8s/ ไม่อ่าน .env เอง)
render() {
  sed -e "s|API_IMAGE_PLACEHOLDER|$API_IMAGE|g" -e "s|BO_IMAGE_PLACEHOLDER|$BO_IMAGE|g" -e "s|APP_TAG_PLACEHOLDER|$APP_TAG|g" \
      -e "s|API_PORT_PLACEHOLDER|$API_PORT|g" -e "s|BO_PORT_PLACEHOLDER|$BO_PORT|g" -e "s|API_HEALTH_PLACEHOLDER|$API_HEALTH_PATH|g" \
      -e "s|RDS_SECRET_PLACEHOLDER|$K8S_SECRET|g" -e "s|APP_SECRET_PLACEHOLDER|$APP_SECRET|g" -e "s|TUNNEL_SECRET_PLACEHOLDER|$TUNNEL_SECRET|g" \
      -e "s|CLOUDFLARED_REPLICAS_PLACEHOLDER|$CLOUDFLARED_REPLICAS|g" -e "s|MIGRATE_CMD_PLACEHOLDER|$MIGRATE_CMD|g" "$1"
}

# ---------- RDS snapshot ----------
snapshot_id() { echo "$LAB_NAME-$1-$(date +%Y%m%d-%H%M)" | sed -E 's/[^A-Za-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//'; }   # snapshot_id <prefix เช่น pre-v1.2.3> (RDS รับแค่ a-z 0-9 -)

# ---------- Cloudflare ----------
# มี CF_API_TOKEN → สคริปต์จัดการ Tunnel + DNS ให้เอง   ไม่มี → cf_manual พิมพ์ค่าให้ไปใส่มือ
cf_manual() {   # cf_manual <ชื่อ record> <ปลายทาง> <คำอธิบาย proxy>
  echo; echo "ไปที่ Cloudflare › DNS แล้วสร้าง/แก้ record:"
  echo "  Type  : CNAME"; echo "  Name  : $1"; echo "  Target: $2"; echo "  Proxy : $3"; echo
}
cf_api() {   # cf_api METHOD PATH [JSON body]   พิมพ์ response JSON ออก stdout
  local data=()
  [[ -n "${3:-}" ]] && data=(--data "$3")
  curl -sS -X "$1" "https://api.cloudflare.com/client/v4$2" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" ${data[@]+"${data[@]}"}
}
cf_ok() {   # อ่าน response จาก stdin: success=true → 0   ไม่ใช่ → พิมพ์ errors[].code+message ไป stderr แล้วคืน 1
  local r; r=$(cat)
  jq -e .success > /dev/null 2>&1 <<< "$r" && return 0
  local msg
  msg=$(jq -r '(.errors // [])[] | "    cloudflare: [\(.code)] \(.message)"' <<< "$r" 2> /dev/null) \
    || { echo "    cloudflare: response ไม่ใช่ JSON: ${r:0:200}" >&2; return 1; }
  echo "${msg:-    cloudflare: success=false (ไม่มีรายละเอียด error)}" >&2
  return 1
}
cf_zone_id()    { cf_api GET "/zones?name=$ZONE" | jq -r '.result[0].id // empty'; }
cf_account_id() { cf_api GET "/zones?name=$ZONE" | jq -r '.result[0].account.id // empty'; }
cf_record_id()  { cf_api GET "/zones/$1/dns_records?type=CNAME&name=$2" | jq -r '.result[0].id // empty'; }
cf_upsert_cname() {   # cf_upsert_cname <ชื่อเต็ม> <ปลายทาง> <true|false = proxied>  สร้างใหม่หรือแก้ของเดิมให้ตรง
  local zid rid body
  zid=$(cf_zone_id); [[ -n "$zid" ]] || { echo "ไม่พบโซน $ZONE ใน Cloudflare (ตรวจ CF_API_TOKEN)" >&2; return 1; }
  body=$(jq -n --arg n "$1" --arg c "$2" --argjson p "$3" '{type:"CNAME", name:$n, content:$c, proxied:$p, ttl:1}')
  rid=$(cf_record_id "$zid" "$1")
  if [[ -n "$rid" ]]; then cf_api PUT "/zones/$zid/dns_records/$rid" "$body" | cf_ok
  else                     cf_api POST "/zones/$zid/dns_records" "$body" | cf_ok; fi
}
cf_delete_cname() {   # cf_delete_cname <ชื่อเต็ม>   คืน 1 ถ้าไม่มี record
  local zid rid
  zid=$(cf_zone_id); rid=$(cf_record_id "$zid" "$1")
  [[ -n "$rid" ]] && cf_api DELETE "/zones/$zid/dns_records/$rid" | cf_ok
}

# --- Cloudflare Tunnel (remotely-managed: config อยู่ฝั่ง Cloudflare, pod cloudflared รับแค่ token) ---
cf_tunnel_id() { cf_api GET "/accounts/$1/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id // empty'; }
cf_tunnel_create() {   # cf_tunnel_create <account-id>  พิมพ์ tunnel id
  local r; r=$(cf_api POST "/accounts/$1/cfd_tunnel" "$(jq -n --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')")
  cf_ok <<< "$r" || return 1
  jq -r '.result.id' <<< "$r"
}
cf_tunnel_token() {   # cf_tunnel_token <account-id> <tunnel-id>
  local r; r=$(cf_api GET "/accounts/$1/cfd_tunnel/$2/token")
  cf_ok <<< "$r" || return 1
  jq -r '.result' <<< "$r"
}
cf_tunnel_configure() {   # cf_tunnel_configure <account-id> <tunnel-id>  ingress: DOMAIN_BO → bo, DOMAIN_API → api, อื่นๆ → 404
  cf_api PUT "/accounts/$1/cfd_tunnel/$2/configurations" \
    "$(jq -n --arg hb "$DOMAIN_BO" --arg sb "$BO_TARGET" --arg ha "$DOMAIN_API" --arg sa "$API_TARGET" \
        '{config:{ingress:[{hostname:$hb, service:$sb},{hostname:$ha, service:$sa},{service:"http_status:404"}]}}')" | cf_ok
}
cf_tunnel_status() { cf_api GET "/accounts/$1/cfd_tunnel/$2" | jq -r '.result.status // "unknown"'; }   # inactive | degraded | healthy | down
cf_tunnel_delete() {   # cf_tunnel_delete <account-id> <tunnel-id>  ต้องล้าง connection ที่ค้างก่อน ไม่งั้น API ปฏิเสธ
  cf_api DELETE "/accounts/$1/cfd_tunnel/$2/connections" | cf_ok || return 1
  cf_api DELETE "/accounts/$1/cfd_tunnel/$2" | cf_ok
}
