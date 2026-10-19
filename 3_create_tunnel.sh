#!/bin/bash
# ขั้น 3: Cloudflare Tunnel แทน ALB + ACM: สร้าง tunnel, ตั้ง ingress 2 โดเมน (DOMAIN_BO → bo, DOMAIN_API → api), CNAME ทั้งคู่ แล้วเก็บ token ใน k8s secret
#   มี CF_API_TOKEN → ทำทุกอย่างผ่าน API (token ต้องมี Account › Cloudflare Tunnel › Edit และ Zone › DNS › Edit)
#   ไม่มี          → บอกวิธีสร้างใน Zero Trust dashboard แล้วให้วาง tunnel token (เก็บใน .cf_tunnel_token รอบหน้าไม่ถามซ้ำ)
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools kubectl jq curl; need_kubeconfig; need_api

if [[ -n "$CF_API_TOKEN" ]]; then
  step "1) Tunnel $TUNNEL_NAME (remotely-managed)"
  ACCT=$(cf_account_id); [[ -n "$ACCT" ]] || die "ไม่พบโซน $ZONE หรือ token อ่านโซนไม่ได้ (ต้องมี Zone › DNS › Edit)"
  TID=$(cf_tunnel_id "$ACCT")
  if [[ -n "$TID" ]]; then
    skip "มีอยู่แล้ว: $TID"
  else
    TID=$(cf_tunnel_create "$ACCT") || die "สร้าง tunnel ไม่สำเร็จ (token ต้องมี Account › Cloudflare Tunnel › Edit และบัญชีต้องเปิดใช้ Zero Trust แล้ว)"
    ok "สร้างแล้ว: $TID"
  fi

  step "2) ingress ของ tunnel: $DOMAIN_BO → $BO_TARGET, $DOMAIN_API → $API_TARGET (อื่นๆ → 404)"
  cf_tunnel_configure "$ACCT" "$TID" || die "ตั้ง ingress ไม่สำเร็จ"
  ok "ตั้งแล้ว (idempotent: PUT ทับค่าเดิม)"

  step "3) Cloudflare DNS: $BO_LABEL และ $API_LABEL → $TID.cfargotunnel.com (Proxied)"
  cf_upsert_cname "$DOMAIN_BO"  "$TID.cfargotunnel.com" true || die "สร้าง CNAME $DOMAIN_BO ไม่สำเร็จ"
  cf_upsert_cname "$DOMAIN_API" "$TID.cfargotunnel.com" true || die "สร้าง CNAME $DOMAIN_API ไม่สำเร็จ"
  ok "CNAME พร้อมทั้ง 2 ชื่อ (SSL mode ของโซนไม่มีผลกับ tunnel)"

  TOKEN=$(cf_tunnel_token "$ACCT" "$TID") || die "อ่าน tunnel token ไม่ได้"
else
  step "1) Tunnel $TUNNEL_NAME (สร้างมือใน Zero Trust dashboard)"
  if [[ -s .cf_tunnel_token ]]; then
    TOKEN=$(< .cf_tunnel_token)
    skip "ใช้ token เดิมจาก .cf_tunnel_token"
  else
    cat <<EOT

ไปที่ https://one.dash.cloudflare.com › Networks › Tunnels › Create a tunnel › Cloudflared
  Tunnel name : $TUNNEL_NAME
  หน้า Install connector: คัดลอกเฉพาะ token (ข้อความยาวหลัง 'install ' ในคำสั่ง) ไม่ต้องรันคำสั่งนั้น
  หน้า Public Hostname (Route tunnel) เพิ่ม 2 รายการ:
    1) Subdomain $BO_LABEL   Domain $ZONE   Type HTTP   URL ${BO_TARGET#http://}
    2) Subdomain $API_LABEL  Domain $ZONE   Type HTTP   URL ${API_TARGET#http://}
  Cloudflare จะสร้าง CNAME ทั้ง 2 ชื่อ → <tunnel-id>.cfargotunnel.com ให้เอง

EOT
    read -rp "วาง tunnel token แล้วกด Enter: " TOKEN
    [[ -n "$TOKEN" ]] || die "ไม่ได้ใส่ token"
    printf '%s' "$TOKEN" > .cf_tunnel_token && chmod 600 .cf_tunnel_token
    ok "เก็บไว้ที่ .cf_tunnel_token"
  fi
fi

step "4) Kubernetes secret $TUNNEL_SECRET (pod cloudflared อ่านเป็น env TUNNEL_TOKEN)"
kubectl create secret generic "$TUNNEL_SECRET" --from-literal=token="$TOKEN" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
ok "secret พร้อม"

echo
echo "แนะนำตั้งเพิ่มใน Cloudflare dashboard (สคริปต์ไม่แตะ): WAF managed rules, rate limit /api/v1/auth/*, Bot Fight Mode และ Access จำกัด $DOMAIN_BO ตาม email (ดู README)"
echo "ถัดไป: ./4_create_secrets.sh"
