#!/bin/bash
# เครื่องมือเสริม: เปิด tunnel ไป k3s API (6443 บนเครื่อง server) ผ่าน SSM แล้ว kubectl/Lens ในเครื่องต่อที่ 127.0.0.1:$K8S_LOCAL_PORT
#   SG ไม่เปิด 6443 ออกอินเทอร์เน็ต ทุกอย่างจึงเข้าทาง SSM (หลักการเดียวกับ connect_rds.sh ต่างกันแค่ปลายทาง)
# ใช้: ./connect_k8s.sh                  เปิดค้างไว้ใน terminal หนึ่ง จนกด Ctrl+C
#      K8S_LOCAL_PORT=6443 ./connect_k8s.sh
# แล้วใน terminal อื่น: export KUBECONFIG=<dir>/kubeconfig && kubectl get po -A
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl session-manager-plugin; need_aws; need_kubeconfig

NODE=$(server_id); [[ -n "$NODE" ]] || die "ไม่พบ instance $LAB_NAME-server รัน ./1_create_cluster.sh ก่อน"
ssm_online "$NODE" || die "instance $NODE ยังไม่ Online ใน SSM (รอ 1-2 นาทีหลังเครื่องขึ้น)"
! api_up || die "มีอะไรฟังอยู่ที่ $API_LOCAL แล้ว (tunnel เปิดค้างใน terminal อื่น?) ถ้าพอร์ตชนกับโปรแกรมอื่น: K8S_LOCAL_PORT=<พอร์ตว่าง> ./connect_k8s.sh"
api_set_kubeconfig

cat <<EOT
Node : $NODE
API  : https://$API_LOCAL  →  SSM  →  127.0.0.1:6443 บนเครื่อง k3s server

terminal อื่นใช้ได้เลย:
  export KUBECONFIG=$LAB_DIR/kubeconfig
  kubectl get po -A
Lens: File › Add Cluster › วางเนื้อหาไฟล์ $LAB_DIR/kubeconfig (ต้องเปิด tunnel นี้ค้างไว้)
กด Ctrl+C เพื่อปิด tunnel

EOT
aws ssm start-session \
  --target "$NODE" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"6443\"],\"localPortNumber\":[\"$K8S_LOCAL_PORT\"]}"
