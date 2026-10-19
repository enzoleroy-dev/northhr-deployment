#!/bin/bash
# เครื่องมือเสริม: ยิง request ใส่ Service api จากใน cluster แล้วดู HPA เพิ่ม replica (ใช้ทดสอบก่อนเปิดใช้งานจริง ไม่ควรรันระหว่างมีผู้ใช้)
# ใช้: ./load_test.sh          ยิง 120 วินาที
#      ./load_test.sh 300      ยิง 300 วินาที
# หลังหยุดยิง HPA จะลด replica กลับเป็น min หลังจาก CPU ต่ำต่อเนื่อง ~5 นาที
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools kubectl; need_kubeconfig; need_api
DURATION=${1:-120}
LOADERS=3

kubectl get hpa api > /dev/null 2>&1 || die "ไม่พบ HPA api รัน ./5_deploy.sh ก่อน"
cleanup() { echo; echo "หยุดยิง ลบ pod load"; kubectl delete pod -l app=load --ignore-not-found --wait=false > /dev/null 2>&1; }
trap cleanup EXIT

step "1) สร้าง pod ยิง load $LOADERS ตัว (busybox วน wget ใส่ http://api:$API_PORT$API_HEALTH_PATH)"
for ((i = 1; i <= LOADERS; i++)); do
  kubectl run "load-$i" --image=busybox:stable --restart=Never --labels=app=load --command -- \
    /bin/sh -c "while true; do wget -q -O- http://api:$API_PORT$API_HEALTH_PATH > /dev/null 2>&1; done" > /dev/null 2>&1 \
    && ok "load-$i" || skip "load-$i มีอยู่แล้ว"
done

step "2) ดู HPA $DURATION วินาที (TARGETS = CPU ปัจจุบัน / เป้า 60%, REPLICAS ควรเพิ่มภายใน 1-2 นาที)"
kubectl get hpa api bo -w &
WATCH=$!
sleep "$DURATION"
kill "$WATCH" 2> /dev/null
echo
kubectl get pods -l app=api -o wide
