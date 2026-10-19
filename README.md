# northhr PROD: EC2 + k3s + Cloudflare Tunnel + hr-bo / hr-api + RDS

`hr_mobile / browser → Cloudflare edge → Tunnel → cloudflared pod → hr-bo / hr-api pod → RDS:5432`
Region `ap-southeast-1` · cluster `northhr-prod` (server t4g.medium + agent t4g.small × 2) · `https://hr.nthw.dev` (hr-bo) · `https://api.hr.nthw.dev` (hr-api)

สคริปต์ชุดนี้ต่อยอดจาก [lab k3s](../aws-ec2-k3s-cloudflared-app-rds-lab/) (โครง `common.sh` / `.env` / tag `lab=` เดียวกัน) แต่ปรับเป็น environment PROD ของระบบ northhr ตาม [เอกสารระบบ](https://nthw-dev.vercel.app/northhr/index.html):

| | lab k3s | PROD northhr |
|---|---|---|
| node | server 1 เครื่อง t4g.small | server t4g.medium + agent t4g.small × 2 (คนละ AZ) สร้างในขั้น 1 |
| workload | `app` 1 ตัว | `api` (hr-api, HPA 2–6) + `bo` (hr-bo, HPA 2–4) + `cloudflared` × 3 + Job `migrate` ทุก release |
| โดเมน | 1 | 2: `DOMAIN_BO` → Service `bo:3000`, `DOMAIN_API` → Service `api:3000` (ingress ของ tunnel) |
| RDS | db.t4g.micro single-AZ ไม่ backup | db.t4g.small **Multi-AZ**, encrypted, backup 7 วัน (PITR), deletion protection, storage 50→100 GB autoscaling, snapshot ก่อน migrate ทุกครั้ง |
| secret | `rds-credentials`, `cloudflared-token` | + `POSTGRES_PRISMA_URL` ใน `rds-credentials`, + `app-secrets` (JWT/SMTP/Maps/S3) จากไฟล์ `app-secrets.env` |
| อื่นๆ | – | S3 bucket + IAM user สิทธิ์เฉพาะ bucket, CloudWatch alarm → email (ถ้าตั้ง `ALARM_EMAIL`), `rollback.sh` |

ค่าใช้จ่ายราว **$4.5–5/วัน** (~$140/เดือน): EC2 t4g.medium + t4g.small × 2 ≈ $1.9, EBS 90 GB ≈ $0.25, RDS db.t4g.small Multi-AZ ≈ $2.2, storage/backup ≈ $0.3, EIP/S3/SNS เล็กน้อย

## สิ่งที่ต้องมีก่อน

- `aws` `kubectl` `jq` `curl` `openssl` `session-manager-plugin` (`brew install --cask session-manager-plugin`) และ `aws sso login --profile enzodev`
- image `northhr/hr-api` และ `northhr/hr-bo` บน Docker Hub (build arm64) ที่ tag ที่จะ deploy
- Cloudflare API token (แนะนำ) สิทธิ์ `Account › Cloudflare Tunnel › Edit` + `Zone › DNS › Edit` ของโซน `nthw.dev` → `echo cf_xxx > .cf_token && chmod 600 .cf_token` (วิธีสร้างดู README ของ lab k3s) ถ้าไม่มี ขั้น 3 จะบอกวิธีทำมือ
- `cp app-secrets.env.example app-secrets.env` แล้วใส่ค่าจริง (JWT, SMTP, Google Maps) ชื่อ key ต้องตรงกับที่ hr-api/hr-bo อ่าน

## ติดตั้งครั้งแรก (6 ขั้น ตามลำดับ)

ทุกสคริปต์รันซ้ำได้ (ข้ามของที่มีแล้ว) รันจากที่ไหนก็ได้ และบอกตอนจบว่าขั้นถัดไปคืออะไร

| ขั้น | คำสั่ง | ทำอะไร | รอ | ต้องทำมือ |
|---|---|---|---|---|
| 1 | `./1_create_cluster.sh` | VPC (public subnet 2 AZ ไม่มี NAT) + IAM role SSM + SG (ไม่มี inbound) + EIP + EC2 server k3s + agent × `AGENT_COUNT` แล้วดึง `kubeconfig` | 5–8 นาที | – |
| 1.5 | `./connect_k8s.sh` | **เปิด tunnel ไป k8s API ค้างไว้ในอีก terminal** ขั้น 2–5, `verify.sh`, `logs.sh`, `rollback.sh` ต้องใช้ | ค้างไว้ | เปิด terminal ที่สอง |
| 2 | `./2_create_rds.sh` | subnet group + SG + RDS Multi-AZ + secret `rds-credentials` (+ SNS/alarm ถ้าตั้ง `ALARM_EMAIL`) | 15–20 นาที | กด Confirm ในเมลของ SNS |
| 3 | `./3_create_tunnel.sh` | Cloudflare Tunnel + ingress 2 โดเมน + CNAME 2 ชื่อ + secret `cloudflared-token` | 1 นาที | ถ้าไม่มี API token: สร้าง tunnel ใน Zero Trust แล้ววาง token |
| 4 | `./4_create_secrets.sh` | S3 bucket (versioning, block public, lifecycle) + IAM user + access key → รวมกับ `app-secrets.env` เป็น secret `app-secrets` | 1 นาที | กรอก `app-secrets.env` ก่อน |
| 5 | `APP_TAG=v1.0.0 ./5_deploy.sh` | snapshot RDS → Job `migrate` → apply `k8s/` → rollout → เช็ก `https://api.hr.nthw.dev/api/v1/health` และ `https://hr.nthw.dev` = 200 | 2–4 นาที | – |

แล้ว `./verify.sh` ตรวจทุกชั้น และ `./load_test.sh` ดู HPA ทำงาน (ก่อนเปิดใช้งานจริง)

## ขึ้นเวอร์ชันใหม่ / ย้อนกลับ

```bash
APP_TAG=v1.2.3 ./5_deploy.sh          # ทั้ง api และ bo ใช้ tag เดียวกัน
SKIP_SNAPSHOT=1 APP_TAG=v1.2.3 ./5_deploy.sh   # deploy ซ้ำ tag เดิม ไม่ต้องถ่าย snapshot อีก
SKIP_MIGRATE=1 ./5_deploy.sh          # แก้แค่ manifest/secret ไม่มี migration
./rollback.sh                         # kubectl rollout undo deploy/api deploy/bo + รอ rollout
./rollback.sh api                     # เฉพาะ api
```

ลำดับใน `5_deploy.sh`: ถ่าย snapshot `northhr-prod-pre-<tag>-<เวลา>` (จาก standby ของ Multi-AZ ไม่กระทบ primary) → ลบ Job `migrate` เก่า สร้างใหม่ด้วย image `hr-api:<tag>` รัน `MIGRATE_CMD` (`npx prisma migrate deploy`) `backoffLimit: 0` ล้มแล้วหยุดทันที pod เวอร์ชันเดิมยังรันอยู่ → apply `k8s/api.yaml` `bo.yaml` `cloudflared.yaml` (RollingUpdate `maxUnavailable: 0` + readiness probe = ไม่มีช่วงไม่มี pod รับ request) → รอ `rollout status` → curl ทั้ง 2 โดเมนผ่าน Cloudflare

migration ต้อง **backward-compatible** (expand → migrate → contract) เพราะระหว่าง rolling update pod เก่ากับใหม่รันพร้อมกัน ถ้า migration ทำให้ code เก่าพัง `rollback.sh` อย่างเดียวไม่พอ ต้อง restore RDS จาก snapshot `pre-<tag>` ด้วย (สคริปต์พิมพ์คำสั่งให้)

เปลี่ยนค่าใน `app-secrets.env` → `./4_create_secrets.sh` แล้ว `kubectl rollout restart deploy/api deploy/bo` (pod อ่าน secret ตอนเริ่มเท่านั้น)

## ต่อ cluster / DB จากเครื่อง (ผ่าน SSM ไม่เปิดพอร์ตใน SG)

```bash
./connect_k8s.sh                        # terminal 1 ค้างไว้: kubectl/Lens → 127.0.0.1:16443 → SSM → 6443 บน server
export KUBECONFIG=$PWD/kubeconfig       # terminal 2
kubectl get hpa,pods -o wide
./logs.sh api 200   ./logs.sh bo   ./logs.sh cloudflared   ./logs.sh migrate   FOLLOW=1 ./logs.sh api

./connect_rds.sh                        # DBeaver/psql/pg_dump → localhost:15432 → SSM บน server → RDS:5432
```

ดูเร็วๆ โดยไม่เปิด tunnel: `source ./common.sh && ssm_run "$(server_id)" "$K3S kubectl get po -A"`

## ขยาย

- **pod** HPA ของ `api` (2–6) และ `bo` (2–4) ที่ CPU 60% ของ request ปรับใน `k8s/*.yaml` แล้ว `SKIP_SNAPSHOT=1 SKIP_MIGRATE=1 ./5_deploy.sh` ระวัง connection ไป RDS = pod api × `DB_POOL_PER_POD` (5) ต้องไม่เกิน `max_connections` ของ db.t4g.small (~400 แต่ memory 2 GB แนะนำไม่เกิน 50–80)
- **node** `./add_node.sh [N]` เพิ่ม agent (`AGENT_TYPE`) แล้วแก้ `AGENT_COUNT` ใน `.env` ให้ตรง / ลด: `kubectl drain` + `kubectl delete node` + terminate
- **เครื่องใหญ่ขึ้น** แก้ `SERVER_TYPE`/`AGENT_TYPE` แล้ว stop → modify → start ทีละเครื่อง (PDB `minAvailable: 1` กันไม่ให้ drain จนไม่เหลือ pod) หรือ `DB_CLASS` ด้วย `aws rds modify-db-instance --apply-immediately` (Multi-AZ จะ failover ~1 นาที)
- **cloudflared** `CLOUDFLARED_REPLICAS` ใน `.env` (anti-affinity แบบ preferred: กระจายคนละ node เท่าที่มี)

## ลบทิ้ง

```bash
./6_destroy.sh                          # ต้องพิมพ์ northhr-prod ยืนยัน เก็บ final snapshot ของ RDS, ปล่อย S3 bucket ไว้
./6_destroy.sh --yes                    # ไม่ถาม
NO_FINAL_SNAPSHOT=1 DELETE_S3=1 ./6_destroy.sh --yes   # ลบเกลี้ยงรวม DB และไฟล์ใน S3
```

ลำดับ: deployment ใน k3s → ปิด deletion protection + สั่งลบ RDS (final snapshot `northhr-prod-final-<เวลา>` เว้นแต่ `NO_FINAL_SNAPSHOT=1`) และ terminate EC2 ทุกตัว → EIP → รอ RDS หาย + subnet group → alarm + SNS → SG → subnet/RT/IGW/VPC → IAM role + user S3 (+ access key) → S3 (เฉพาะ `DELETE_S3=1`) → tunnel + CNAME 2 ชื่อ → ไฟล์ `.db_password` `.cf_tunnel_token` `.s3_access_key` `kubeconfig` (ไม่แตะ `app-secrets.env` / `.cf_token`) ราว 10–15 นาที ส่วนใหญ่คือรอ RDS Multi-AZ

snapshot (pre-*, final) ไม่ถูกลบอัตโนมัติ มีค่าเก็บ ~$0.095/GB-เดือน: `aws rds describe-db-snapshots --snapshot-type manual` แล้ว `delete-db-snapshot` เมื่อไม่ใช้

`../aws_audit.sh` จะเห็น resource ชุดนี้เป็นกลุ่ม `stack:northhr-prod` (ไม่ใช่ lab 1–3) ลบด้วยสคริปต์นี้เท่านั้น เพราะ `destroy_stack.sh` ไม่รู้จัก deletion protection ของ RDS, S3, SNS และ IAM user

## ตั้งค่า (.env)

ค่าคงที่ทั้งหมดอยู่ใน [.env](.env) ทุกบรรทัด `VAR=${VAR:-ค่า}` ค่าที่ `export` ใน shell ชนะค่าในไฟล์

| ตัวแปร | ค่าปัจจุบัน | ใช้ที่ |
|---|---|---|
| `LAB_NAME` | `northhr-prod` | prefix ของทุก resource + tag `lab=` |
| `VPC_CIDR` / `SUBNET_CIDRS` | `10.20.0.0/16` / `10.20.0.0/24 10.20.1.0/24` | VPC และ subnet คนละ AZ **ห้ามทับ** `POD_CIDR`/`SVC_CIDR` (10.42/10.43) |
| `SERVER_TYPE` / `AGENT_TYPE` / `AGENT_COUNT` / `DISK_GB` | `t4g.medium` / `t4g.small` / `2` / `30` | เครื่องของ cluster (arm64, EBS gp3 encrypted) |
| `K3S_VERSION` | (ว่าง = stable) | ควร pin ใน PROD เช่น `v1.31.4+k3s1` |
| `ZONE` / `DOMAIN_BO` / `DOMAIN_API` | `nthw.dev` / `hr.nthw.dev` / `api.hr.nthw.dev` | โซนและโดเมนของ hr-bo / hr-api (hr_mobile build ด้วย `BASE_URL=https://DOMAIN_API`) |
| `CF_API_TOKEN` / `TUNNEL_NAME` / `TUNNEL_SECRET` / `CLOUDFLARED_REPLICAS` | (ว่าง) / `northhr-prod` / `cloudflared-token` / `3` | Cloudflare Tunnel |
| `API_IMAGE` / `BO_IMAGE` / `APP_TAG` | `northhr/hr-api` / `northhr/hr-bo` / `latest` | image (arm64) ขึ้นเวอร์ชัน: `APP_TAG=x ./5_deploy.sh` |
| `API_PORT` / `BO_PORT` / `API_HEALTH_PATH` | `3000` / `3000` / `/api/v1/health` | พอร์ตใน container และ path ที่ readiness/deploy ใช้เช็ก |
| `MIGRATE_CMD` / `DB_POOL_PER_POD` | `npx prisma migrate deploy` / `5` | คำสั่งใน Job migrate และ `connection_limit` ใน `POSTGRES_PRISMA_URL` |
| `DB_ID` / `DB_CLASS` / `DB_ENGINE_VERSION` | `northhr-prod` / `db.t4g.small` / `16` | RDS |
| `DB_NAME` / `DB_USER` | `northhr` / `northhr` | database และ master user (รหัสสุ่ม 24 ตัวอักษร a-z A-Z 0-9 ใน `.db_password`) |
| `DB_STORAGE_GB` / `DB_MAX_STORAGE_GB` / `DB_BACKUP_DAYS` | `50` / `100` / `7` | gp3 + autoscaling, automated backup |
| `K8S_SECRET` / `APP_SECRET` / `SECRETS_FILE` | `rds-credentials` / `app-secrets` / `app-secrets.env` | secret ที่ pod อ่านเป็น env |
| `S3_BUCKET` / `S3_USER` / `S3_NONCURRENT_DAYS` | (ว่าง = `northhr-prod-files-<account>`) / `northhr-prod-s3` / `30` | bucket ไฟล์ของ hr-api, IAM user, lifecycle |
| `ALARM_EMAIL` | (ว่าง) | ถ้าตั้ง ขั้น 2 สร้าง SNS + alarm CPU>80% / พื้นที่<5GiB / memory<200MiB |
| `LOCAL_PORT` / `K8S_LOCAL_PORT` | `15432` / `16443` | พอร์ตในเครื่องของ SSM tunnel |

**เปลี่ยนค่ากลางคัน** ถ้าแก้ `LAB_NAME` `DB_ID` หรือโดเมนหลังสร้างของไปแล้ว สคริปต์จะมองไม่เห็นของเดิม รัน `./6_destroy.sh` ด้วยค่าเก่าก่อน

## secret ที่ pod ได้รับ

| secret | key | มาจาก | ใครอ่าน |
|---|---|---|---|
| `rds-credentials` | `DB_HOST` `DB_PORT` `DB_NAME` `DB_USER` `DB_PASSWORD` `POSTGRES_PRISMA_URL` (`...?schema=public&connection_limit=5`) | ขั้น 2 | api, migrate |
| `app-secrets` | ทุกบรรทัดใน `app-secrets.env` + `AWS_REGION` `AWS_ACCESS_KEY_ID` `AWS_SECRET_ACCESS_KEY` `AWS_S3_BUCKET` `CORS_ALLOWED_ORIGINS` (เติมให้ถ้าไม่มีในไฟล์) | ขั้น 4 | api, bo, migrate |
| `cloudflared-token` | `token` | ขั้น 3 | cloudflared |

env ที่ใส่ตรงใน manifest: `PORT` `NODE_ENV=production` และ `BACKEND_API_URL=http://api:3000` ของ bo
ไฟล์ใน `k8s/` ไม่อ่าน `.env` มี placeholder (`API_IMAGE_PLACEHOLDER` `APP_TAG_PLACEHOLDER` `API_PORT_PLACEHOLDER` `RDS_SECRET_PLACEHOLDER` `APP_SECRET_PLACEHOLDER` `TUNNEL_SECRET_PLACEHOLDER` `CLOUDFLARED_REPLICAS_PLACEHOLDER` `MIGRATE_CMD_PLACEHOLDER` ...) ที่ `render` ใน `common.sh` แทนค่าตอน apply

## Cloudflare: สิ่งที่ตั้งเพิ่มเองใน dashboard (สคริปต์ไม่แตะ)

- **WAF** Security › WAF › Managed rules เปิด Cloudflare Managed Ruleset
- **Rate limiting** rule สำหรับ `api.hr.nthw.dev` path `/api/v1/auth/*` เช่น 10 req/นาที/IP
- **Bot Fight Mode** Security › Bots
- **Access (ไม่บังคับ)** Zero Trust › Access › Applications จำกัด `hr.nthw.dev` ให้ email ขององค์กร (API และ mobile ต้องเปิดสาธารณะ)
- SSL mode ของโซนไม่มีผลกับ tunnel (TLS จบที่ edge, edge → cloudflared เข้ารหัสใน tunnel)

## ไฟล์ที่สคริปต์สร้างเอง (อยู่ใน .gitignore)

| ไฟล์ | เนื้อหา |
|---|---|
| `kubeconfig` | kubeconfig ของ k3s (server = `https://127.0.0.1:16443` ปลาย tunnel) |
| `.db_password` | รหัส master ของ RDS (กู้จาก secret ได้ด้วย `connect_rds.sh` หรือรันขั้น 2 ซ้ำ) |
| `.cf_token` / `.cf_tunnel_token` | Cloudflare API token / tunnel token ที่วางมือ |
| `.s3_access_key` | access key ของ IAM user S3 (ขั้น 4 ใช้ซ้ำ ถ้าลบไฟล์จะออก key ใหม่) |
| `app-secrets.env` | ค่าที่คุณกรอก (คัดลอกจาก `app-secrets.env.example`) |

## ปัญหาที่เจอบ่อย

ปัญหาเรื่อง CIDR ชน, tunnel/SSM, kubectl ต่อไม่ได้, cloudflared Unauthorized, 530/1033/502 เหมือน lab k3s ดูที่ [README ของ lab นั้น](../aws-ec2-k3s-cloudflared-app-rds-lab/README.md#ปัญหาที่เจอบ่อย) เพิ่มเติมเฉพาะชุดนี้:

- **Job migrate ล้ม** → `./logs.sh migrate` มักเป็น `POSTGRES_PRISMA_URL` ผิด (รันขั้น 2 ซ้ำ) หรือ image ไม่มี prisma CLI (แก้ `MIGRATE_CMD` ใน `.env` ให้ตรงกับ image เช่น `node node_modules/prisma/build/index.js migrate deploy`)
- **pod api CrashLoop หลัง deploy** → `./logs.sh api` ถ้าเป็น env หาย เช็กชื่อ key ใน `app-secrets.env` ตรงกับที่ hr-api อ่านหรือไม่ (`kubectl get secret app-secrets -o jsonpath='{.data}' | jq 'keys'`)
- **bo ได้ 200 แต่เรียก api ไม่ได้ (CORS)** → `CORS_ALLOWED_ORIGINS` ใน app-secrets ต้องเป็น `https://hr.nthw.dev` (ขั้น 4 เติมให้ถ้าไม่ใส่เอง)
- **4_create_secrets.sh: user มี access key ครบ 2 ตัว** → `.s3_access_key` หายแต่ key ยังอยู่ใน IAM: `aws iam list-access-keys --user-name northhr-prod-s3` แล้ว `delete-access-key` ตัวที่ไม่ใช้
- **6_destroy.sh: RDS ลบไม่ได้** → deletion protection ยังเปิด (สคริปต์ปิดให้ แต่ต้องรอ status available ก่อน) รันซ้ำ
- **agent join ไม่ได้ (ขั้น 1 ค้างที่ "รอ node Ready ครบ")** → `aws ssm start-session --target <agent-id>` แล้ว `journalctl -u k3s-agent` มักเป็น SG ไม่มี rule node↔node หรือ token เปลี่ยน (server ถูกสร้างใหม่)
- **HPA api ขึ้นถึง 6 แล้ว RDS connection เต็ม** → ลด `DB_POOL_PER_POD` แล้วรันขั้น 2 ซ้ำ + `kubectl rollout restart deploy/api` หรือเพิ่ม `DB_CLASS`
