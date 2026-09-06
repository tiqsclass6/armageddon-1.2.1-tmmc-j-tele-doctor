# **Armageddon 1.2.1 Runbook**

Tokyo Midtown Medical Center (TMMC) **J-Tele-Doctor**: seven-region hub-and-spoke on AWS, syslog and PII in Japan, spokes send-only to Tokyo SIEM. Specs: `Armageddon-Project-Class-6-V1.1.docx` and `V1.2.docx` in this folder.

Work from the repo root. Terraform lives in `terraform/`. Deploy/test with `scripts/3-run-lab.sh`. Tear down with `scripts/4-teardown-lab.sh`.

```text
Armageddon 1.2.1/
├── documentation/
│   ├── Armageddon-Project-Class-6-V1.1.docx
│   ├── Armageddon-Project-Class-6-V1.2.docx
│   ├── armageddon.png
│   ├── Armageddon.xlsx
│   └── RUNBOOK.md
├── scripts/
│   ├── 1-user-data.sh
│   ├── 2-grafana.sh
│   ├── 3-run-lab.sh
│   └── 4-teardown-lab.sh
│
├── terraform/
│   ├── 0-providers.tf
│   ├── 1-variables.tf
│   ├── 2-new-york.tf
│   ├── 3-london.tf
│   ├── 4-sao-paulo.tf
│   ├── 5-sydney.tf
│   ├── 6-hong-kong.tf
│   ├── 7-california.tf
│   ├── 8-tokyo.tf
│   ├── 9-aurora-db.tf
│   ├── 10-siem.tf
│   ├── 11a-tgw-new-york.tf
│   ├── 11b-tgw-london.tf
│   ├── 11c-tgw-sao-paulo.tf
│   ├── 11d-tgw-sydney.tf
│   ├── 11e-tgw-hong-kong.tf
│   ├── 11f-tgw-california.tf
│   ├── 12-ami.tf
│   ├── A-backend.tf
│   └── B-outputs.tf
│
├── .gitignore
└── README.md
```

Last live validation: E2E **66 PASS / 1 WARN / 0 FAIL** (WARN = Tokyo `1c` public+restricted overlap). Teardown via `scripts/4-teardown-lab.sh` destroyed **269** resources. Remote S3 state was kept. The stack is down until the next `3-run-lab.sh`.

---

## **1. What “done” looks like**

| **Spec**                                                 | **Proof**                                                                    |
| -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **Local app in 7 places**                                | HTTP 200 from each regional ALB on **port 80 only**                          |
| **ASG, 2 AZs, ≥1 EC2**                                   | Each region: ASG min 2, instances in two private AZs, **no public IP**       |
| **Syslog reaches Japan**                                 | Promtail pushes to Tokyo Loki NLB `:3100` over **TGW** (no VPN)              |
| **Syslog stays in Japan**                                | Loki + syslog S3 in Tokyo; replica in Osaka (`ap-northeast-3`)               |
| **PII stays in Japan**                                   | Aurora PostgreSQL in Tokyo; spokes have **no route** to DB subnets           |
| **Syslog / DB AZ has no public subnet**                  | SIEM + DB in restricted AZs; **1d has no public subnet**. See AZ note below. |
| **DB and SIEM are different subnets**                    | SIEM `10.230.60.0/24`–`61.0/24`; DB `10.230.51.0/24`–`52.0/24`               |
| **A.1 SIEM fault tolerant**                              | SIEM ASG **min/max 2** across two restricted AZs                             |
| **A.2 basic EC2**                                        | Launch template + `scripts/2-grafana.sh`                                     |
| **A.3 spokes send-only**                                 | Spokes can hit Loki `:3100`; they cannot hit Grafana `:3000` or SSH          |
| **A.4 Terraform outputs**                                | `a3_*` outputs in `terraform output`                                         |

Automatic fail if you store syslog or PII outside Japan, move PII over a VPN, put a public subnet in a syslog/DB AZ, or colocate DB and SIEM in the same subnet.

**Tokyo AZ note:** this account has `ap-northeast-1a`, `1c`, and `1d` only. App public ALBs need two AZs (`1a`/`1c`). Aurora and the Loki NLB also need two AZs, so restricted subnets are `1d` + `1c`. **`1d` has no public subnet. `1c` also has app public subnets.** That is an account limit, not a leftover bug.

---

## **2. Architecture**

```text
Internet --:80--> regional ALB (public AZs)
                    |
                    v
              App ASG (private AZs) + Promtail
                    |
                    |  spokes: 10.230.60.0/23 only
                    v
              Regional TGW ----peering---- Tokyo hub TGW
                                              |
                    +-------------------------+----------------+
                    v                                          v
         SIEM 10.230.60.0/23                          DB 10.230.51.0/24
         (1d + 1c)                                    10.230.52.0/24
         Loki NLB :3100  (spokes + Tokyo)             (Tokyo app SG only)
         Grafana ALB :3000 (Tokyo VPC only)
```

| **Location**                   | **AWS region**   | **VPC CIDR**    |
| ------------------------------ | ---------------- | --------------- |
| Tokyo (hub)                    | `ap-northeast-1` | `10.230.0.0/16` |
| New York                       | `us-east-1`      | `10.231.0.0/16` |
| London                         | `eu-west-2`      | `10.232.0.0/16` |
| Sao Paulo                      | `sa-east-1`      | `10.233.0.0/16` |
| Sydney                         | `ap-southeast-2` | `10.234.0.0/16` |
| Hong Kong                      | `ap-east-1`      | `10.235.0.0/16` |
| California                     | `us-west-1`      | `10.236.0.0/16` |
| Osaka (syslog S3 replica only) | `ap-northeast-3` | —               |

Tokyo splits:

- App public/private: `ap-northeast-1a`, `1c` (`10.230.1–2.0/24`, `10.230.11–12.0/24`)
- Restricted: `ap-northeast-1d`, `1c`
  - DB: `10.230.51.0/24`, `10.230.52.0/24`
  - SIEM: `10.230.60.0/24`, `10.230.61.0/24` (`local.syslog_cidr` = `10.230.60.0/23`)

CIDR sheet: `Armageddon.xlsx`. Ops diagram: `armageddon.png` (CIDRs/AZs match this table; regenerate with `python scripts/render-architecture.py` if Terraform changes).

One Tokyo VPC. No VPN. Spokes route **only** `10.230.60.0/23`, not the full Tokyo VPC and not the DB subnets.

---

## **3. Prerequisites**

- Terraform ≥ 1.0 (validated with 1.14.x)
- AWS CLI v2, Python 3, curl, bash (Git Bash on Windows)
- Credentials that can build in all eight regions above
- **Hong Kong (`ap-east-1`) and Osaka (`ap-northeast-3`) enabled** (Account → Regions)
- S3 state bucket `armageddon-tiqs-state-files` in `us-east-1` (`terraform/A-backend.tf`)

Create the bucket if it is missing:

```bash
aws s3api create-bucket --bucket armageddon-tiqs-state-files --region us-east-1
aws s3api put-bucket-encryption --bucket armageddon-tiqs-state-files --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}"
aws s3api put-bucket-versioning --bucket armageddon-tiqs-state-files --versioning-configuration Status=Enabled
```

This lab is expensive: 7 NAT gateways, 7 public ALBs, 2 internal LBs, Aurora (2× `db.t3.medium`), TGW peering, hours of t2/t3. Do not leave it up overnight without a reason.

Hong Kong instances are `t3.micro` (no `t2` in `ap-east-1`). Other app regions are `t2.micro`.

---

## **4. One-command deploy and live E2E**

From the repo root, in Git Bash:

```bash
bash scripts/3-run-lab.sh
```

The script prints colored phases and a results table. Every step is numbered **01/15 through 15/15**:

1. `01/15` Prerequisites (AWS identity, opt-in regions, tool versions)
2. `02/15` `terraform init -upgrade`
3. `03/15` `terraform fmt -recursive`
4. `04/15` `terraform validate`
5. `05/15` `terraform plan -out=tfplan`
6. `06/15` `terraform apply tfplan`
7. `07/15` `terraform output`
8. `08/15`–`15/15` Live E2E (ALBs, ASGs, A.3/A.4, TGW routes, no VPN, Loki, Grafana, Aurora, S3)

Useful flags:

```bash
bash scripts/3-run-lab.sh --skip-apply        # already applied; still init/fmt/validate/plan, then test
bash scripts/3-run-lab.sh --skip-terraform    # test current state only
bash scripts/3-run-lab.sh --plan-only         # stop after plan
```

Artifacts land in `run-artifacts/<utc-timestamp>/` (log, plan, outputs, curl bodies, TSV results). The latest session env is copied to `.lab-session.env`.

First apply is **25–45 minutes**. Loki user-data can take a few more minutes after apply before `/ready` is 200.

If the stack is already up, re-test with `--skip-terraform`. A full run with empty local state will plan **269 creates** and rebuild the lab.

Do **not** run Terraform from the repo root.

---

## **5. Manual Terraform (if you are not using the script)**

```bash
cd terraform
terraform init -upgrade
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

Sensitive Aurora password:

```bash
terraform output -raw aurora_master_password
```

---

## **6. What the E2E actually hits**

| **Phase**          | **Live check**                                                                    |
| ------------------ | --------------------------------------------------------------------------------- |
| **Public apps**    | curl each ALB; expect 200 and **Samurai Katana**                                  |
| **Listeners**      | each ALB has **port 80 only**                                                     |
| **ASGs**           | min/desired ≥ 2, ≥ 2 AZs, instances have no public IP                             |
| **SIEM A.1**       | ASG min=max=2                                                                     |
| **A.4 outputs**    | syslog CIDR `10.230.60.0/23`; spoke TGW routes match; SIEM ≠ DB CIDRs             |
| **Spoke routes**   | private RTs have TGW to syslog only — not `10.230.0.0/16`, not DB                 |
| **No VPN**         | no VGW / Site-to-Site VPN in app regions or Osaka                                 |
| **Restricted AZs** | `1d` has no public subnet; `1c` overlap is a **WARNING** (account AZ limit)       |
| **Loki**           | NLB targets healthy; SSM `/ready` = 200 on SIEM; laptop curl = `000` (internal)   |
| **Grafana**        | internal ALB targets healthy; SG allows `10.230.0.0/16` only; NACL denies 3000/22 |
| **Promtail**       | launch-template user-data contains `http://<loki-nlb>:3100/loki/api/v1/push`      |
| **Aurora**         | cluster in `ap-northeast-1`, encrypted, 5432 from `tokyo-ec2-sg` only             |
| **Syslog S3**      | Tokyo bucket + Osaka replica                                                      |

The Loki NLB and Grafana ALB are **internal**. Curl from a laptop to `:3100` / `:3000` returning `000` is expected. `sudo` is a Linux command; run it on EC2, not Git Bash.

App ASGs have **no SSM instance profile**. Promtail on spokes is proven from launch-template user-data. Loki `/ready` is proven with SSM on **SIEM_Server** instances (they do have SSM).

---

## **7. Demo order**

1. Architecture: `armageddon.png` — Tokyo hub, six spokes, TGW, no VPN.
2. Browser: all seven ALB URLs on port 80.
3. `terraform output` / the script results table — A.4 artifacts.
4. Console: Loki NLB target group healthy; Grafana target group healthy.
5. Grafana UI — SSM port-forward (below). Do not expect `http://<grafana-alb>:3000` from a laptop; that ALB is internal.
6. Optional SSM shell: `aws ssm start-session --region ap-northeast-1 --target i-<siem>` then `curl http://127.0.0.1:3100/ready`.
7. Console: Tokyo `1d` has no public subnet; SIEM vs DB CIDRs differ.

### Grafana UI login

Grafana is **internal** (Tokyo VPC `10.230.0.0/16` only). App ASGs have no SSM; SIEM instances (`Name=SIEM_Server`) do. Use Session Manager port forwarding so the browser stays on your laptop and Grafana stays private.

Requires the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) and a running lab (`bash scripts/3-run-lab.sh`).

```bash
SIEM_ID=$(aws ec2 describe-instances --region ap-northeast-1 \
  --filters "Name=tag:Name,Values=SIEM_Server" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[0].InstanceId" --output text)

aws ssm start-session \
  --region ap-northeast-1 \
  --target "$SIEM_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=3000,localPortNumber=3000
```

Leave that session open. In a browser:

1. Open `http://localhost:3000`
2. Username: **`admin`**
3. Password: **`admin`**
4. Grafana will prompt you to set a new password on first login. That change lives on the instance only (it is not in Terraform).

**Loki has no username or password** (`auth_enabled: false`). After login, add a Loki data source if it is missing: URL `http://127.0.0.1:3100` (Grafana and Loki share the SIEM instance). Use **Explore** to query `job=webserver` (Apache) and `job=system` (`/var/log/*.log`). There is no pre-built CloudWatch/metrics dashboard — this stack is log aggregation, not CPU/ALB graphs.

A curl to the Grafana ALB DNS from your laptop returning `000` is expected. Do not open Grafana to `0.0.0.0/0`; that would break A.3.

---

## **8. File map**

| **File**                    | **Purpose**                                           |
| --------------------------- | ----------------------------------------------------- |
| `0-provider.tf`             | AWS `~> 6.63`, random `~> 3.9`, 7 app regions + Osaka |
| `1-variables.tf`            | AZs, `syslog_cidr`, spoke CIDRs                       |
| `2`–`8.tf`                  | Regional VPC / ALB / ASG                              |
| `9-aurora-db.tf`            | Aurora in Tokyo restricted AZs                        |
| `10-siem.tf`                | SIEM subnets, NLB, Grafana ALB, NACL, S3              |
| `11a`–`11f`                 | TGW + peering to Tokyo                                |
| `12-ami.tf`                 | Amazon Linux 2023 AMIs per region                     |
| `A-backend.tf`              | S3 state                                              |
| `B-outputs.tf`              | Demo + A.4 artifacts                                  |
| `scripts/1-user-data.sh`    | Apache + Promtail (Loki NLB DNS templated)            |
| `scripts/2-grafana.sh`      | Loki + Grafana on SIEM instances                      |
| `scripts/3-run-lab.sh`      | Deploy + live E2E (01/15–15/15)                       |
| `scripts/4-teardown-lab.sh` | Empty syslog buckets + destroy                        |

---

## **9. Troubleshooting**

| **Symptom**                                                                      | **Likely Cause**                                 | **Fix**                                                                                                          |
| -------------------------------------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| **`ap-east-1` not enabled**                                                      | Hong Kong opt-in                                 | Enable `ap-east-1` in the account                                                                                |
| **Subnet AZ `ap-northeast-1b` invalid**                                          | Account has no `1b`                              | Restricted AZs are already `1d` + `1c`                                                                           |
| **TGW `IncorrectState`**                                                         | Peering still pending                            | Re-apply; associations wait on the accepter                                                                      |
| **SG description invalid**                                                       | Non-ASCII (`—`)                                  | Descriptions must be ASCII                                                                                       |
| **ALB unhealthy / timeout**                                                      | ASG still booting                                | Wait ~5 min; rerun `bash scripts/3-run-lab.sh --skip-terraform`                                                  |
| **E2E FAIL public IPs / TGW `syslog_routes=3`**                                  | Git Bash ate aws `--query` backticks             | Fixed in `3-run-lab.sh`; rerun `--skip-terraform` (do **not** full-run or Terraform will recreate 269 resources) |
| **Loki `/ready` 503 via SSM**                                                    | Loki HTTP not ready yet; NLB TCP already healthy | Script retries for `SIEM_WAIT_SECONDS`; wait and rerun `--skip-terraform`                                        |
| **Loki `/ready` 000 from laptop**                                                | Internal NLB                                     | Use SSM on SIEM, or trust NLB target health                                                                      |
| **Grafana UI `000` from laptop**                                                 | Internal ALB; not public                         | SSM port-forward to `SIEM_Server`:3000; log in `admin` / `admin`. Loki has no password.                          |
| **Loki targets unhealthy**                                                       | Loki 2.8 rejected `allow_structured_metadata`    | Already removed from `scripts/2-grafana.sh`; instance-refresh SIEM if an old box is stuck                        |
| **`sudo: command not found`**                                                    | Command ran on Windows                           | SSM onto Linux EC2                                                                                               |
| **`terraform init` backend error**                                               | Bucket missing                                   | Create `armageddon-tiqs-state-files` in `us-east-1`                                                              |

---

## **10. Destroy**

```bash
bash scripts/4-teardown-lab.sh
```

Type `DESTROY-ARMAGEDDON` when prompted. Non-interactive:

```bash
bash scripts/4-teardown-lab.sh --yes
```

Phases **01/08–08/08**: init, snapshot state, empty versioned Tokyo/Osaka syslog buckets, destroy plan, confirm, destroy, leftover check.
Optional flags: `--purge-session`, `--remove-terraform-cache`.
Confirm NAT gateways, TGWs, ALBs, Aurora, and S3 replica buckets are gone. Remote state remains in `s3://armageddon-tiqs-state-files/armageddon-class6.tfstate` until you delete that object.

---

## **11. Spec Checklist**

Use this on the next live run. Last full E2E was green except the documented `1c` WARN.

- [ ] 7 regional apps, ALB:80 public only
- [ ] ASG ≥ 2 AZs, ≥ 1 EC2 (this stack uses desired 2)
- [ ] Syslog to Japan via TGW; no VPN
- [ ] Syslog stored in Japan (Tokyo Loki + S3; Osaka replica still JP)
- [ ] PII in Japan only (Aurora Tokyo); spokes cannot route to DB
- [ ] Syslog AZ has no public subnet (`1d`; `1c` caveat documented)
- [ ] DB AZ has no public subnet (`1d`; `1c` caveat documented)
- [ ] DB and SIEM are different subnets
- [ ] SIEM ASG size 2 in two AZs (A.1) on basic EC2 (A.2)
- [ ] Spokes send Loki only; cannot access Grafana/SSH (A.3)
- [ ] `terraform output` includes `a3_*` (A.4)
- [ ] `bash scripts/3-run-lab.sh --skip-apply` (or full run) is green
