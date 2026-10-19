#!/bin/bash
# เครื่องมือเสริม (ขยายแนวนอน): เพิ่ม k3s agent N เครื่อง (AGENT_TYPE) เข้า cluster เดิม นอกเหนือจาก AGENT_COUNT ที่ขั้น 1 สร้างไว้
# ใช้: ./add_node.sh        เพิ่ม 1 เครื่อง
#      ./add_node.sh 2      เพิ่ม 2 เครื่อง (สลับ AZ)
# ลด: kubectl drain <node> --ignore-daemonsets --delete-emptydir-data && kubectl delete node <node> แล้ว aws ec2 terminate-instances --instance-ids <id>
# (ไม่ต้องเปิด connect_k8s.sh: นับ node ผ่าน SSM) หลังเพิ่ม ถ้าจะให้ cloudflared กระจายไปเครื่องใหม่: kubectl rollout restart deploy/cloudflared
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws jq; need_aws
N=${1:-1}

step "1) สร้าง agent $N เครื่อง ($AGENT_TYPE) มีอยู่แล้ว $(instance_ids agent | wc -w | tr -d ' ')"
launch_agents "$N"

step "2) node ทั้งหมด"
ssm_run "$(server_id)" "$K3S kubectl get nodes -o wide"
echo
echo "ถ้าอยากคง agent จำนวนนี้ไว้ถาวร ให้แก้ AGENT_COUNT ใน .env (verify.sh ใช้ค่านี้นับ node)"
