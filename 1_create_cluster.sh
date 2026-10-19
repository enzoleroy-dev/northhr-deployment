#!/bin/bash
# ขั้น 1: VPC (public subnet 2 AZ ไม่มี NAT) + IAM role สำหรับ SSM + SG + Elastic IP + EC2 server ที่ติดตั้ง k3s ผ่าน user-data
#         + agent อีก AGENT_COUNT เครื่อง (สลับ AZ) แล้วดึง kubeconfig มาไว้ที่ ./kubeconfig (ไม่มี SSH key ไม่เปิด 6443 ทุกอย่างผ่าน SSM)
# รันซ้ำได้: ข้ามของที่มีแล้ว และเติม agent ให้ครบ AGENT_COUNT
set -euo pipefail
source "$(dirname "$0")/common.sh"
need_tools aws kubectl jq; need_aws

# ---- 0) กัน CIDR ชนกัน (ทุกค่าเป็น /16 เทียบแค่ 2 octet แรก) ----
for c in "$POD_CIDR" "$SVC_CIDR"; do
  [[ "${VPC_CIDR%.*.*}" == "${c%.*.*}" ]] && die "VPC_CIDR $VPC_CIDR ทับกับ $c (POD_CIDR/SVC_CIDR ของ k3s) แก้ .env ให้เป็นช่วงอื่น"
done

# ---- 1) VPC ----
step "1) VPC $LAB_NAME ($VPC_CIDR) + IGW + route table + subnet"
VPC_ID=$(lab_vpc)
if [[ -n "$VPC_ID" ]]; then
  skip "VPC มีอยู่แล้ว: $VPC_ID"
else
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(tags vpc "$LAB_NAME")" --query Vpc.VpcId --output text)
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames   # RDS endpoint และ SSM ต้องการ DNS hostname
  ok "VPC: $VPC_ID"
fi
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" --output text | sed '/^None$/d')
if [[ -n "$IGW_ID" ]]; then
  skip "IGW มีอยู่แล้ว: $IGW_ID"
else
  IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway "$LAB_NAME")" --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  ok "IGW: $IGW_ID"
fi
RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$LAB_NAME" \
  --query "RouteTables[0].RouteTableId" --output text | sed '/^None$/d')
if [[ -n "$RT_ID" ]]; then
  skip "route table มีอยู่แล้ว: $RT_ID"
else
  RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tags route-table "$LAB_NAME")" --query RouteTable.RouteTableId --output text)
  aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
  ok "route table: $RT_ID (0.0.0.0/0 → IGW)"
fi
read -ra AZS <<< "$(aws ec2 describe-availability-zones --query "AvailabilityZones[?State=='available'].ZoneName" --output text)"
SERVER_SUBNET=""; i=0
for cidr in $SUBNET_CIDRS; do
  az=${AZS[$i]}
  SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$cidr" \
    --query "Subnets[0].SubnetId" --output text | sed '/^None$/d')
  if [[ -n "$SUBNET" ]]; then
    skip "subnet $cidr มีอยู่แล้ว: $SUBNET"
  else
    SUBNET=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "$(tags subnet "$LAB_NAME-$az")" --query Subnet.SubnetId --output text)
    aws ec2 modify-subnet-attribute --subnet-id "$SUBNET" --map-public-ip-on-launch   # ไม่มี NAT: ทุก node ต้องมี public IP เพื่อดึง image
    aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET" > /dev/null
    ok "subnet $cidr ($az): $SUBNET"
  fi
  [[ -z "$SERVER_SUBNET" ]] && SERVER_SUBNET=$SUBNET   # server อยู่ subnet แรก
  i=$((i + 1))
done

# ---- 2) IAM ----
step "2) IAM role/instance profile $ROLE_NAME (AmazonSSMManagedInstanceCore)"
if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  skip "role มีอยู่แล้ว"
else
  aws iam create-role --role-name "$ROLE_NAME" --tags "Key=lab,Value=$LAB_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > /dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  ok "สร้าง role แล้ว"
fi
if aws iam get-instance-profile --instance-profile-name "$ROLE_NAME" > /dev/null 2>&1; then
  skip "instance profile มีอยู่แล้ว"
else
  aws iam create-instance-profile --instance-profile-name "$ROLE_NAME" --tags "Key=lab,Value=$LAB_NAME" > /dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
  ok "สร้าง instance profile แล้ว (launch_instance จะ retry ระหว่างที่ IAM propagate)"
fi

# ---- 3) Security group ----
step "3) security group $NODE_SG (ทุกพอร์ตระหว่าง node กันเอง ไม่มี inbound จากภายนอกเลย)"
NODE_SG_ID=$(sg_id "$NODE_SG")
if [[ -n "$NODE_SG_ID" ]]; then
  skip "มีอยู่แล้ว: $NODE_SG_ID"
else
  NODE_SG_ID=$(aws ec2 create-security-group --group-name "$NODE_SG" --description "k3s nodes ($LAB_NAME)" --vpc-id "$VPC_ID" \
    --tag-specifications "$(tags security-group "$NODE_SG")" --query GroupId --output text)
  ok "สร้างแล้ว: $NODE_SG_ID"
fi
aws ec2 authorize-security-group-ingress --group-id "$NODE_SG_ID" --protocol -1 --source-group "$NODE_SG_ID" > /dev/null 2>&1 \
  && ok "node ↔ node (flannel/kubelet)" || skip "rule node ↔ node มีอยู่แล้ว"
for old in $(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$NODE_SG_ID" \
    --query "SecurityGroupRules[?IsEgress==\`false\` && CidrIpv4!=\`null\`].SecurityGroupRuleId" --output text); do
  aws ec2 revoke-security-group-ingress --group-id "$NODE_SG_ID" --security-group-rule-ids "$old" > /dev/null && ok "ลบ inbound rule จาก CIDR ที่เปิดค้างไว้ ($old)"
done
ok "ไม่มี inbound rule จากภายนอก (kubectl เข้าทาง SSM)"

# ---- 4) Elastic IP ----
step "4) Elastic IP (public IP คงที่ข้าม stop/start สำหรับขาออกของ server)"
EIP=$(server_ip)
if [[ -n "$EIP" ]]; then
  skip "มีอยู่แล้ว: $EIP"
else
  EIP=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tags elastic-ip "$LAB_NAME")" --query PublicIp --output text)
  ok "จองแล้ว: $EIP"
fi
ALLOC_ID=$(aws ec2 describe-addresses --public-ips "$EIP" --query "Addresses[0].AllocationId" --output text)

# ---- 5) EC2 server + k3s ----
step "5) EC2 $LAB_NAME-server ($SERVER_TYPE, AL2023) + k3s server ผ่าน user-data (pod $POD_CIDR, service $SVC_CIDR)"
ID=$(server_id)
if [[ -n "$ID" ]]; then
  skip "มีอยู่แล้ว: $ID"
else
  # ปิด traefik/servicelb (ไม่ใช้ Ingress, cloudflared ต่อ Service ตรง) metrics-server ยังเปิดไว้ให้ HPA
  USER_DATA=$(cat <<EOF
#!/bin/bash
curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true ${K3S_VERSION:+INSTALL_K3S_VERSION=$K3S_VERSION} \\
  INSTALL_K3S_EXEC="server --cluster-cidr $POD_CIDR --service-cidr $SVC_CIDR --disable traefik --disable servicelb --write-kubeconfig-mode 644" sh -
EOF
)
  ID=$(launch_instance "$LAB_NAME-server" server "$SERVER_SUBNET" "$USER_DATA" "$SERVER_TYPE") || die "run-instances ไม่สำเร็จ (ดู instance profile $ROLE_NAME / quota ของ $SERVER_TYPE)"
  ok "สั่งสร้างแล้ว: $ID"
fi
aws ec2 wait instance-running --instance-ids "$ID"
if [[ "$(aws ec2 describe-addresses --public-ips "$EIP" --query "Addresses[0].InstanceId" --output text)" == "$ID" ]]; then
  skip "EIP ผูกกับ instance อยู่แล้ว"
else
  aws ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$ID" > /dev/null
  ok "ผูก $EIP กับ $ID"
fi
wait_for "SSM agent Online" 10 30 ssm_online "$ID" || die "instance ยังไม่ Online ใน SSM (ดู instance profile / route ออกเน็ต)"
k3s_ready() { ssm_run "$ID" "$K3S kubectl get nodes 2>/dev/null | grep -q ' Ready'"; }
wait_for "k3s ติดตั้งและ node Ready" 10 30 k3s_ready || die "k3s ยังไม่พร้อม ดู log: aws ssm start-session --target $ID แล้ว journalctl -u k3s"
ok "k3s server พร้อม"

# ---- 6) kubeconfig ----
step "6) kubeconfig → ./kubeconfig (server = https://$API_LOCAL ปลายทางของ SSM tunnel)"
RAW=$(ssm_run "$ID" "cat /etc/rancher/k3s/k3s.yaml") || die "อ่าน /etc/rancher/k3s/k3s.yaml ไม่ได้"
sed "s|https://127.0.0.1:6443|https://$API_LOCAL|" <<< "$RAW" > kubeconfig   # cert ของ k3s ครอบ 127.0.0.1 อยู่แล้ว TLS ไม่ตรวจพอร์ต
chmod 600 kubeconfig
kubectl config rename-context default "$LAB_NAME" > /dev/null 2>&1 || true
ok "เขียนแล้ว (ต่อได้เมื่อเปิด ./connect_k8s.sh)"

# ---- 7) agent ----
HAVE=$(instance_ids agent | wc -w | tr -d ' ')
step "7) k3s agent $AGENT_COUNT เครื่อง ($AGENT_TYPE) มีอยู่แล้ว $HAVE"
if [[ "$HAVE" -ge "$AGENT_COUNT" ]]; then
  skip "ครบแล้ว"
else
  launch_agents $((AGENT_COUNT - HAVE))
  ok "agent ครบ $AGENT_COUNT เครื่อง"
fi

echo
echo "node ที่เห็นจากบนเครื่อง (ผ่าน SSM):"
ssm_run "$ID" "$K3S kubectl get nodes -o wide"

echo
echo "เปิด tunnel ค้างไว้ใน terminal ที่ 1:  $LAB_DIR/connect_k8s.sh"
echo "แล้วใน terminal ที่ 2 ใช้ kubectl เอง: export KUBECONFIG=$LAB_DIR/kubeconfig && kubectl get po -A"
echo "ถัดไป (ต้องมี tunnel เปิดอยู่): ./2_create_rds.sh"
