#!/bin/bash
# เครื่องมือเสริม: ดู log ของ deployment ใน cluster
# ใช้: ./logs.sh                 api 200 บรรทัดล่าสุด
#      ./logs.sh bo 50           bo 50 บรรทัด
#      ./logs.sh cloudflared     หรือ  ./logs.sh migrate (Job ล่าสุด)
#      FOLLOW=1 ./logs.sh api    ตามต่อเนื่อง (Ctrl+C หยุด)
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools kubectl; need_kubeconfig; need_api
SVC=${1:-api}; N=${2:-200}; FOLLOW=${FOLLOW:-0}
case "$SVC" in
  migrate) kubectl logs job/migrate --tail="$N" ;;
  *)       kubectl logs "deploy/$SVC" --all-containers --tail="$N" $([[ "$FOLLOW" == 1 ]] && echo -f) ;;
esac
