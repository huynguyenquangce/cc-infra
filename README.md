# cc-infra — networking / VPN trước

[Đi tới runbook API Proxy UAT/Production](#api-proxy--uat-và-production-cloudfront--alb-internal--vpn--http-9010) ·
[Đi tới runbook MCP Server](#mcp-server--cloudfront--alb-internal--ecs-fargate)

Terraform cho AWS Commerce Casino, dựa trên `CLAUDE.md`, `huy-knowledge.md` và
`codex-knowledge.md` ở workspace cha. Bootstrap/networking hiện có được mở rộng với hai application root.
Đã có ALB API Proxy và MCP Server (CloudFront → ALB internal → ECS Fargate) cho UAT/Production; không có Lambda proxy.

## State và cấu trúc

Trong mỗi module/root, resource, data source và module calls được gom trong
`main.tf`, có comment giải thích mục đích. `variables.tf`, `outputs.tf`,
`providers.tf`, `versions.tf` và `backend.tf` vẫn tách riêng theo chức năng.

| Root | S3 key | Quản lý |
|---|---|---|
| `bootstrap/` | `bootstrap/terraform.tfstate` | S3 state bucket, GitHub OIDC provider, IAM roles networking/UAT/Production |
| `live/networking/` | `networking/terraform.tfstate` | VPC, subnets, route tables, VGW, CGW, VPN, NAT, VPC endpoints, ECR, logs/alarms, SSM contract |
| `live/uat/` | `uat/terraform.tfstate` | ALB API Proxy UAT + MCP Server UAT |
| `live/production/` | `production/terraform.tfstate` | ALB API Proxy Production + MCP Server Production |

**Có 4 root/state: bootstrap, networking, uat, production.** Hai application state chỉ được tạo khi chạy các root tương ứng.
Dùng chung một bucket, tách key và IAM permission. Không dùng Terraform workspace
để chuyển môi trường. Tên application environment là `uat` và `production`.

```text
modules/
  state-backend/    # S3 versioning, SSE-S3 encryption, block public access, HTTPS-only
  github-oidc/      # Exact repository + environment trust, dedicated role/policies
  network/          # Shared VPC, private subnets, optional public subnets + IGW, optional NAT
  vpc-endpoints/    # Interface endpoints (ECR, Logs, Secrets Manager) + S3 gateway
  ecr/              # Shared immutable image repository with lifecycle policy
  vpn/              # VGW + BGP, configurable customer endpoints, two tunnels/connection
  api-proxy/        # Internal ALB -> HTTP 9010 targets over VPN, logs/alarms (edge via cloudfront-vpc-origin)
  mcp-server/       # Internal ALB -> Fargate, secrets, alarms (edge via cloudfront-vpc-origin)
  cloudfront-vpc-origin/  # Shared HTTPS edge: CloudFront default cert + VPC origin to an internal ALB
bootstrap/
live/networking/
live/uat/
live/production/
.github/workflows/  # Validation/tests; manual networking/application operations with OIDC
examples/cc-mcp-server/  # Build/deploy workflow mẫu cho repo ứng dụng (không chạy từ repo này)
```

VGW + BGP là phương án ban đầu cho một VPC dùng chung, cần xác nhận với đội network.
Hai subnet private là phân bổ đề xuất để kiểm tra VPN và mở rộng sau này.
NAT, VPC endpoints và ECR là opt-in (`nat_subnet`, `vpc_endpoint_subnet_keys`,
`ecr_repositories`). Khi `public_subnets` rỗng và không có `nat_subnet` thì chưa có IGW.
Khi điền `nat_subnet`, **private subnets có thêm route `0.0.0.0/0 → NAT`**; route BGP
của Commerce (cụ thể hơn) vẫn đi qua VPN. ALB có SG riêng trong module
application; default VPC SG và NACL do AWS tạo.

## 1. Điền thông số và bootstrap một lần

Yêu cầu Terraform >= 1.10 (CI dùng 1.13.5), AWS provider 6.x; AWS CLI/session SSO
hoặc temporary credential có quyền provision bootstrap. Không dùng access key dài
hạn trong GitHub. Bootstrap chạy bằng danh tính quản trị vì chưa có bucket/OIDC.
Không tự chạy apply từ workspace này.

**Giải thích `bucket = "REPLACE-cc-terraform-state"` trong file example:** đây là
placeholder cho **tên S3 bucket lưu Terraform state**, không phải tên dùng nguyên
xi. Bạn chọn tên trước; lần apply bootstrap sẽ tạo bucket đó. Không cần tạo bucket
thủ công trước bootstrap.

Ví dụ chọn `commerce-casino-tfstate-123456789012` (thay số bằng Account ID thật;
Account ID là mã AWS account gồm 12 chữ số, không phải access key). Tên bucket
phải duy nhất trong AWS partition đang dùng; dùng chữ thường, số và dấu gạch ngang
cho dễ đặt tên. Không thêm `s3://` hay `/terraform.tfstate` vào tên bucket.

Các giá trị sau phải dùng **cùng một tên bucket**:

| File / cấu hình | Trường | Ví dụ |
|---|---|---|
| `bootstrap/terraform.tfvars` | `state_bucket_name` | `"commerce-casino-tfstate-123456789012"` |
| `bootstrap/backend.hcl` | `bucket` | `"commerce-casino-tfstate-123456789012"` |
| `live/networking/backend.hcl` (nếu chạy local) | `bucket` | `"commerce-casino-tfstate-123456789012"` |
| GitHub Environment variable (nếu chạy Actions) | `STATE_BUCKET` | `commerce-casino-tfstate-123456789012` |

`state_bucket_name` yêu cầu Terraform **tạo bucket**; `bucket` trong backend yêu
cầu Terraform **lưu state vào bucket đã tồn tại**. Bootstrap và networking dùng
chung bucket nhưng khác `key`: `bootstrap/terraform.tfstate` và
`networking/terraform.tfstate`. OIDC cung cấp credential tạm cho workflow, không
thay thế tên bucket hay Account ID trong cấu hình.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
# Điền account, region, bucket name và repository segment của GitHub OIDC sub.
# Sửa backend.hcl cùng bucket/region, giữ key bootstrap/terraform.tfstate.
terraform init
terraform fmt -recursive ..
terraform validate
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Ban đầu bootstrap dùng local state để giải quyết việc bucket chưa tồn tại. Sau apply,
copy `bootstrap/backend.tf.example` thành `bootstrap/backend.tf` (hoặc dùng nội dung
sau), rồi migrate ngay:

```hcl
terraform {
  backend "s3" {}
}
```

```bash
terraform init -migrate-state -backend-config=backend.hcl
# Trả lời yes khi Terraform hỏi copy state; xác minh migration thành công.
terraform plan
terraform output github_role_arns
```

Commit `bootstrap/backend.tf` sau khi migrate; giữ nó trong repo từ đó trở đi.
`backend.hcl`, local state/backup, plan và tfvars thật đã được gitignore. Bảo quản/xóa
bản local state theo quy trình nội bộ sau khi xác minh bản S3. Bucket có
`prevent_destroy` và `force_destroy=false`. Không có lifecycle tự xóa state versions.

Nếu AWS account đã có GitHub OIDC provider, điền
`existing_github_oidc_provider_arn`; không tạo provider thứ hai cho cùng issuer.
Sau `terraform init` thành công, commit `.terraform.lock.hcl` của **mỗi root**;
không commit `.terraform/`. Chạy `terraform providers lock -platform=linux_amd64`
nếu bootstrap từ máy khác platform. Các root hiện có lock file; review thay đổi
lock khi chủ động nâng provider, không dùng `init -upgrade` như bước deploy thường lệ.

## 2. Sau bootstrap: chọn cách provision networking

Sau khi migrate bootstrap thành công, S3 đang chứa state của **bucket + OIDC + IAM**
ở key `bootstrap/terraform.tfstate`. Networking chưa được provision.

Networking là một root riêng: lần chạy đầu sẽ tạo state mới ở
`networking/terraform.tfstate` trong **cùng bucket**. Không copy bootstrap state
sang networking và không chạy `-migrate-state` cho networking mới.

Có hai cách chạy, cùng quản lý một networking state:

- **GitHub Actions + OIDC:** làm theo mục 3. Đây là cách chạy CI đã chuẩn bị cho repo.
  Không cần apply networking local trước.
- **Local:** dùng session AWS SSO/temporary credentials có quyền tạo networking
  và đọc/ghi key networking trong bucket. OIDC trong repo chỉ dành cho GitHub Actions,
  không tự đăng nhập AWS cho terminal trên máy bạn. Chạy các lệnh dưới đây.

```bash
cd ../live/networking
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
# Điền account/region, bucket, CIDR, subnet/AZ, AWS ASN, Commerce endpoint(s).
terraform init -backend-config=backend.hcl
terraform fmt -recursive ../..
terraform validate
terraform plan -out=networking.tfplan
terraform apply networking.tfplan
terraform output vpn_connections
```

`customer_gateways` trong example cố ý để rỗng; validation yêu cầu điền ít nhất một
endpoint đã xác nhận. Không tự suy diễn hai IP trong tài liệu thành hai thiết bị HA.
Một entry = một CGW + một VPN connection + hai tunnel. Hai entry = bốn tunnel.
Giữ map key ổn định: đổi tên entry có thể khiến Terraform thay connection.
AWS tự cấp tunnel outside IP, inside /30 và PSK; IP trong screenshot cũ không được
hardcode. PSK/config thiết bị lấy từ AWS console qua kênh được phép, không đưa vào Git.

## 3. GitHub Actions OIDC

Đưa **nội dung cc-infra** lên root của repo riêng có đúng repository trong tfvars
bootstrap. Workflow không dùng path prefix `cc-infra/`. Mặc định branch là `main`;
nếu repo dùng tên khác, sửa workflows và branch restrictions cùng lúc.

Có thể tạo repo GitHub trước để biết chính xác `OWNER/REPO`, rồi bootstrap local,
migrate bootstrap state lên S3, push code và cấu hình Environment. Không bắt buộc
đợi bootstrap xong mới push code; workflow networking chỉ chạy được khi bootstrap
và cấu hình Environment đã hoàn tất. File workflow đã nằm trong `.github/workflows/`,
push lên là GitHub nhận diện, không cần tạo lại workflow bằng giao diện.

| Đẩy lên GitHub | Giữ local, không commit |
|---|---|
| Code `.tf` trong `bootstrap/`, `live/`, `modules/` | File giá trị thật `*.tfvars`, `*.tfvars.json` |
| Các file `*.example` để hướng dẫn điền | `backend.hcl` thật |
| `.github/`, `.gitignore`, `README.md` | Thư mục `.terraform/` |
| `.terraform.lock.hcl` của mỗi root sau init | `*.tfstate`, backup state, `*.tfplan`, `crash.log` |
| `bootstrap/backend.tf` sau khi migrate | AWS credentials, GitHub token, VPN PSK/config có secret |

Chỉ push nội dung thư mục `cc-infra`, không push toàn bộ workspace `Casino/`.
Trước commit, xem `git status --short` và `git diff --cached`; không dùng `git add -f`
để đưa các file bị ignore lên repo. File `NETWORKING_TFVARS` được cấu hình bằng
Environment secret, không phải file cần commit. Account ID và bucket name không
phải credential; việc ignore tfvars giúp quản lý cấu hình thật ngoài repo theo
workflow hiện tại.

Thực hiện lần lượt sau bootstrap:

**Bước 1 — Lấy role ARN.** Trong thư mục `bootstrap/` đã migrate S3, chạy:

```bash
terraform output github_role_arns
```

Lấy giá trị của key `networking`, dạng
`arn:aws:iam::<ACCOUNT_ID>:role/cc-terraform-networking`.

**Bước 2 — Chuẩn bị giá trị networking.** Copy
`live/networking/terraform.tfvars.example` thành `live/networking/terraform.tfvars`
và điền account/region, VPC/subnet CIDR, AZ, AWS ASN, Commerce endpoint(s) đã xác nhận.
`customer_gateways` phải có ít nhất một entry; các entry trong example đang comment.
File này chỉ chuẩn bị input, không tạo tài nguyên AWS. Không cần điền
`backend.hcl` khi dùng workflow: workflow tự cấu hình backend bằng GitHub variables.

**Bước 3 — Cấu hình GitHub Environment.** Vào repo → Settings → Environments,
tạo **`networking`** trước khi chạy workflow:

- Deployment branches: chỉ `main`. Bật required reviewers theo quy trình của team.
  Branch restriction trên Environment cần thiết vì OIDC subject theo environment
  không chứa branch; điều kiện `if` trong workflow chỉ là kiểm tra bổ sung.
- Environment variables: `AWS_REGION`, `AWS_ACCOUNT_ID`, `STATE_BUCKET`,
  `AWS_ROLE_ARN` (output bootstrap cho networking).
- Environment secret `NETWORKING_TFVARS`: **toàn bộ nội dung HCL** của file
  `live/networking/terraform.tfvars` đã điền; không phải đường dẫn, không phải JSON.
  Không có PSK trong file này. Workflow truyền account/region từ variables bằng
  CLI để provider/backend luôn dùng cùng account/region.

Ví dụ mapping cấu hình (thay placeholder bằng giá trị thực):

| Loại | Tên | Giá trị |
|---|---|---|
| Variable | `AWS_ACCOUNT_ID` | Account đã bootstrap, ví dụ `123456789012` |
| Variable | `AWS_REGION` | Region triển khai, ví dụ `us-east-1` |
| Variable | `STATE_BUCKET` | Tên bucket bootstrap đã tạo; không thêm `s3://` hay key |
| Variable | `AWS_ROLE_ARN` | Role ARN lấy ở bước 1 |
| Secret | `NETWORKING_TFVARS` | Paste toàn bộ nội dung HCL đã điền ở bước 2 |

**Bước 4 — Plan.** Vào Actions → Networking Terraform → Run workflow,
chọn branch `main`, operation `plan`. Nếu có Environment approval, reviewer duyệt
để job bắt đầu. Kiểm tra log plan và các tài nguyên dự kiến tạo. Lần này chưa tạo
VPC/VPN; backend có thể tạo/cập nhật metadata state và lock phục vụ Terraform.

**Bước 5 — Apply.** Sau khi review plan, chạy workflow lại trên cùng commit với
operation `apply`. Workflow lấy AWS credential tạm qua OIDC, tạo plan mới rồi apply.
Networking state được lưu thẳng vào S3 ở key `networking/terraform.tfstate`.
Không có bước migrate local state ở đây.

**Bước 6 — Cấu hình phía Commerce.** Sau apply, vào AWS VPC → Site-to-Site VPN
connections, lấy vendor configuration và trao đổi PSK qua kênh được phép. Đội
Commerce cấu hình IPsec/BGP/MSS; kiểm tra tunnels, learned routes và traffic theo
mục 6. AWS provision thành công chưa đồng nghĩa VPN hai đầu đã hoạt động.

Trust policy dùng `StringEquals` cho cả `aud=sts.amazonaws.com` và
`sub=repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:networking` với repo này.
Giá trị `github_repository` trong bootstrap phải khớp phần repository của `sub`
trong token GitHub. CloudTrail `AssumeRoleWithWebIdentity` ghi nhận giá trị này
khi trust policy từ chối token. GitHub có thể dùng dạng cũ `OWNER/REPO`
cho repo khác; không wildcard repo/branch.
Role chỉ ghi `networking/terraform.tfstate` + lock tương ứng, không có quyền đọc
bootstrap state hay sửa IAM. Networking mutation giới hạn AWS region; EC2 actions
liệt kê tường minh nhưng vẫn quản lý được networking khác trong region vì nhiều
API EC2 và read actions dùng Resource `*`. Đây chưa phải boundary theo VPC/tag.

Chạy workflow **Networking Terraform**, chọn `plan` để xem trước; sau review chọn
`apply` ở cùng commit. Lần apply tạo **plan mới** rồi apply đúng saved plan trong
cùng job. Environment approval diễn ra trước job, không nằm giữa plan/apply; xem
lại plan mới trong log. Không có auto-apply/destroy khi push/PR. Workflow có thêm `plan-destroy` và
`destroy` với xác nhận riêng; xem mục Destroy networking bên dưới.
PR chỉ chạy `init -backend=false` + `validate`, không nhận AWS credential.
Không upload binary plan/state vì có thể chứa PSK. Concurrency và S3 locking tránh
hai lần chạy cùng ghi state. Workflow `plan` vẫn dùng role networking có quyền ghi;
chưa tách role read-only. Phiên OIDC hết hạn sau một giờ, job timeout 55 phút.

## 4. VPN: các giá trị phải xác nhận

| Thông số | Trong code | Cần kiểm tra |
|---|---|---|
| Region | example `us-east-1` | Theo design; IP AWS trong screenshot không chứng minh region này |
| VPC CIDR | example `10.0.0.0/16` | Không overlap Commerce/on-prem/peering; `10.0.0.230` trong screenshot là dấu hiệu cần đối chiếu |
| AWS VGW ASN | example `64512` | AWS ASN khác Commerce ASN |
| Commerce ASN | đề cập `64583` trong example comment | Xác nhận với đội network |
| Commerce endpoints | hai IP ghi chú, chưa bật | Một HA pair hay hai CGW/connection độc lập? |
| Crypto | IKEv2, AES256, SHA2-256, DH19 phase 1/2 | Khớp Cisco FTD3120 và contract phase 2/PFS |
| Lifetime | 28800 / 3600 giây | Giá trị đề xuất AWS defaults, cho phép override |
| Route | BGP, propagate vào các private route table | Commerce quảng bá đúng CIDR, không quảng bá default/overlap |
| Failover/failback | Không ép primary/backup trong Terraform | Chốt policy BGP cả hai chiều và test thực tế |
| MSS | Đội Commerce clamp MSS **1387** | Cấu hình trên thiết bị, không phải thuộc tính Terraform VPN |

VGW route propagation nhận route BGP, **không phải prefix filter**. Phải giới hạn
advertisement ở phía Commerce; traffic selector rộng mặc định không có nghĩa
route/firewall tự cho phép mọi traffic. VGW không cung cấp ECMP như TGW.
VPC dùng chung có local routing giữa các subnet; việc tách state không tạo network
isolation. Khi thêm staging/prod phải bổ sung SG và rule truy cập rõ ràng.

VPN resource ở storage mode Standard, AWS-generated PSK/config có thể xuất hiện
trong raw Terraform state dù không có output PSK. Vì vậy state bucket là dữ liệu
nhạy cảm: encryption/versioning/HTTPS-only + IAM giới hạn key. Không cấp application
role quyền đọc networking state; IDs được publish vào SSM String parameter
`/cc/networking/contract`. SSE-S3 hiện không cần customer-managed AWS KMS key.

Có CloudWatch VPN logs retention 90 ngày và alarm từng tunnel down sau 3 chu kỳ
60 giây. Điền `alarm_action_arns` với SNS topic đã có để nhận notification; rỗng
thì chỉ có alarm trong CloudWatch. SNS topic/subscription chưa được tạo ở phase này.

## 5. Update sau khi networking đã chạy

**Được update bình thường trên cùng networking state**, không cần tạo lại stack:

```bash
# Sửa module hoặc terraform.tfvars; giữ nguyên backend bucket/key.
terraform plan -out=networking.tfplan
# Kiểm tra cả additions, changes và replacements trước khi apply.
terraform apply networking.tfplan
```

Có thể thêm subnet, NAT, endpoints, VPN endpoint mới bằng module hiện tại hoặc module
mới. Khi thêm loại tài nguyên ngoài VPN phase, mở rộng IAM policy networking trong
bootstrap tương ứng rồi apply bootstrap trước. Thêm map key mới thường thêm tài nguyên; đổi CIDR subnet/VPC, customer endpoint
hoặc VGW ASN có thể thay tài nguyên và gián đoạn VPN. Khi refactor module/resource
address, dùng `moved` block để giữ mapping state, không xóa state để chạy lại.
Backend bucket name không đổi chỉ vì đổi VPC; nếu đổi backend key phải migrate state.

Đã thêm `live/uat` và `live/production`, mỗi root dùng S3 key riêng; đọc SSM contract
bằng data source và chọn subnet được phân bổ cho env đó. Networking tiếp tục sở hữu
VPC/subnet/routes/VPN; application hiện sở hữu CloudFront/ALB/SG/monitoring/log bucket.
Không khai báo một resource ở hai state. Roles và workflow API Proxy đã có; bootstrap
cần được plan/apply khi cập nhật quyền IAM.

## 6. Acceptance sau apply

Apply success chỉ xác nhận AWS đã provision. Đội Commerce còn phải cấu hình cả hai
tunnel của từng connection, PSK, BGP và MSS theo AWS-generated vendor configuration.
Kiểm tra TunnelState, BGP Established, route nhận đúng prefix, route table AWS và
đường về Commerce. Dùng test host/workload được cho phép trong private subnet để
kiểm tra traffic hai chiều, SG/NACL/host firewall, failover từng tunnel và cả endpoint,
sau đó failback theo policy đã chốt. Terraform hiện chưa tạo test host.

## Tham chiếu

- [Terraform S3 backend: locking và IAM](https://developer.hashicorp.com/terraform/language/backend/s3)
- [GitHub OIDC với AWS: audience, subject và Environment](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [AWS provider VPN connection: crypto và sensitive state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpn_connection)

## Incident: SSM DescribeParameters AccessDenied sau networking apply

Nếu VPN đã `Creation complete` nhưng job thất bại ở metadata của
`/cc/networking/contract`, kiểm tra IAM role `cc-terraform-networking` có
`ssm:DescribeParameters`. API này cần statement `Resource = "*"` vì không hỗ trợ
resource-level permission; giới hạn `aws:RequestedRegion` theo region triển khai.
Get/Put/Delete parameter vẫn giới hạn ở `/cc/networking/*`, không mở quyền đọc
mọi parameter value. [AWS SSM IAM actions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ssm.html)

Sau khi sửa `modules/github-oidc/main.tf`, dùng AWS session local có quyền IAM,
chạy từ root repo đang quản lý bootstrap state thật:

```bash
aws sts get-caller-identity
terraform -chdir=bootstrap init -backend-config=backend.hcl
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
# Review: phải cập nhật IAM policy, không tạo lại bucket/VPN.
terraform -chdir=bootstrap apply bootstrap.tfplan
```

Commit/push code sửa policy và chạy workflow networking `plan`, review rồi `apply`
trên cùng S3 bucket/key/input. Đợi IAM propagation nếu vừa cập nhật role.
VPN đã tạo không cần destroy để sửa quyền SSM. Apply có thể đã thành công một phần:
giữ state và kiểm tra plan thực tế, không xóa state hoặc bật overwrite để né lỗi.
Nếu lần sau có lỗi ParameterAlreadyExists, đối chiếu state/resource ownership trước
khi quyết định import; không mặc định import parameter từ deployment khác.

## Destroy networking bằng GitHub Actions

Workflow hiện hỗ trợ cùng bốn operation như bản template `cc-infra`:

| Operation | `destroy_confirmation` | Hành vi |
|---|---|---|
| `plan` | Để trống | Plan thường; không apply |
| `apply` | Để trống | Plan thường mới rồi apply saved plan trong cùng job |
| `plan-destroy` | Để trống | Plan xóa networking; chưa xóa tài nguyên |
| `destroy` | `destroy-networking` | Destroy plan mới rồi apply saved plan trong cùng job |

Trước khi xóa, xác nhận account/region/S3 key networking đúng và phối hợp downtime.
Xử lý application ALB/ECS/Lambda/ENI hoặc dependency đang dùng VPC/subnet trước;
networking dùng chung nên việc xóa ảnh hưởng mọi workload đang sử dụng nó.

1. Push workflow mới lên `main`. Vào **Actions → Networking Terraform → Run workflow**,
   chọn branch `main`, `operation=plan-destroy`, để trống confirmation; review plan.
2. Giữ nguyên commit, GitHub variables và secret `NETWORKING_TFVARS`. Sau khi quyết
   định thực thi, chạy lại `operation=destroy`, nhập chính xác `destroy-networking`.
3. Duyệt Environment `networking` nếu có required reviewers; xem job/apply result.
   Confirm sai hoặc thiếu sẽ fail trước checkout và assume AWS role.
4. Sau khi xóa thành công, kiểm tra AWS không còn tài nguyên networking dự kiến.
   Bootstrap bucket/OIDC/IAM còn nguyên; state object/versions vẫn được giữ lại.

Destroy run tạo **plan mới**, không dùng lại binary plan của run preview. Approval
của Environment nằm trước job, không giữa plan và execution. Không tự đổi secret
sau preview. Không upload plan/state artifact, không xóa state để thay cho destroy.
Concurrency và S3 locking dùng chung với plan/apply. Nếu job lỗi giữa chừng, giữ
state, xử lý nguyên nhân rồi preview/execute lại. Apply sau destroy với cấu hình
còn nguyên sẽ đề xuất tạo lại networking.

Workflow không destroy bootstrap. Bucket có `prevent_destroy`/`force_destroy=false`;
không gỡ protection để cleanup networking. Chưa chạy destroy trên AWS để kiểm thử
thay đổi workflow này.

## API Proxy — UAT và Production (CloudFront → ALB internal → VPN → HTTP 9010)

Đã có module `modules/api-proxy`, hai root **`live/uat`** và
**`live/production`**. Mỗi môi trường có CloudFront distribution, ALB internal, target group,
SG, log bucket, CloudWatch dashboard/alarms và SNS riêng. Không tạo API Gateway/Lambda proxy.

```text
App HTTPS → CloudFront (dxxxx.cloudfront.net, cert mặc định) ─VPC origin─▶ ALB internal :80 (private-a + private-b)
  → shared VGW/VPN → backend private IP HTTP:9010
```

Không dùng custom domain/ACM: app đặt `EXPO_PUBLIC_API_BASE_URL` = output `api_proxy_url`
(`https://dxxxx.cloudfront.net/api`). ALB không có IP public; chỉ nhận cổng 80 từ prefix list
CloudFront origin-facing. Bốn public subnet (`*-alb-*`) vẫn được giữ trong networking nhưng
hiện không đặt ALB nào. Module CloudFront dùng chung với MCP: `modules/cloudfront-vpc-origin`.

| State | Key S3 | Role workflow |
|---|---|---|
| Networking dùng chung | `networking/terraform.tfstate` | `cc-terraform-networking` |
| UAT | `uat/terraform.tfstate` | `cc-terraform-uat` |
| Production | `production/terraform.tfstate` | `cc-terraform-production` |

Các thao tác dưới chạy từ root repo `cc-infra-testing`. Chọn **GitHub Actions**
hoặc **LOCAL** cho application, không apply cả hai nối tiếp. Bootstrap vẫn chạy
local khi sửa IAM. Tên môi trường là `uat` và `production`, không phải staging/prod.

### A. Chuẩn bị nền tảng — LOCAL bootstrap, sau đó networking

1. **LOCAL:** dùng AWS SSO/credential có quyền IAM, plan/apply bootstrap hiện có:

   ```bash
   aws sts get-caller-identity
   terraform -chdir=bootstrap init -backend-config=backend.hcl
   terraform -chdir=bootstrap plan -out=bootstrap.tfplan
   # Review: thêm hai role/policies và quyền IGW/routes; không tạo lại bucket/VPN.
   terraform -chdir=bootstrap apply bootstrap.tfplan
   terraform -chdir=bootstrap output github_role_arns
   ```

2. ALB internal dùng `private-a`/`private-b` (đã có). `public_subnets` không bắt buộc cho
   API Proxy; nếu đã khai báo thì giữ nguyên. AZ ID của private-a/b phải được CloudFront
   VPC origins hỗ trợ (`aws ec2 describe-availability-zones ...`, xem mục MCP).
3. **Nếu networking chạy Actions:** đồng bộ secret `NETWORKING_TFVARS`, chạy
   Networking Terraform `plan` → review → `apply`. **Nếu chạy LOCAL:** init/plan/
   apply `live/networking` trên cùng S3 key hiện có.
4. Kiểm tra VGW route propagation trên **private route tables** (route BGP của Commerce
   tới backend); SSM `/cc/networking/contract` có `subnet_ids` (private-a/b) cho ALB.
   Không đọc raw VPN state từ application.

### B. Inputs application và điều kiện backend

Copy example thành tfvars thật nếu cần soạn local; không commit file thật:

```bash
cp -n live/uat/terraform.tfvars.example live/uat/terraform.tfvars
cp -n live/production/terraform.tfvars.example live/production/terraform.tfvars
```

Điền account/region, backend IPs và người nhận alarms (không cần domain).
Không có backend IP nào được tự điền vào example; map rỗng là chủ ý.
`enable_alb=true` yêu cầu ít nhất một target và một email/alarm action ARN.
Cấu hình target có thể có bốn server đã xác nhận, hoặc một server để kiểm thử có
kiểm soát. Khách hàng/đội backend phải bảo đảm shared datastore và failover đúng
trước khi đăng ký nhiều bản `cc-mock-api` độc lập: YAML/cache trong source hiện
không tự đồng bộ giữa các node. Không coi cookie stickiness là shared datastore.

Backend **HTTP 9010** là cố định trong module theo quyết định đã chốt. Với source
`cc-mock-api`, container vẫn chạy HTTP 8000, nên server phải publish host
`9010:8000` (hoặc reverse proxy tương ứng). Kiểm tra runtime từng server. Commerce
allowlist source **`10.0.10.0/24` và `10.0.11.0/24`** (private-a/b, nơi đặt node ALB internal)
tới backend 9010 và route chiều về qua VPN. Hai dải này dùng chung cho UAT, Production và
ECS MCP, nên Commerce không phân biệt được UAT/Prod theo source IP.

CloudFront không cache, forward mọi header (gồm `Authorization`) trừ Host; backend nhận Host là
tên DNS nội bộ của ALB và path `/api/...` giữ nguyên; backend tự kiểm tra Firebase bearer token.
Rule priority cao chặn `/api/test` và `/api/test/*` bằng 403. Docs/redoc/openapi bị
chặn mặc định; root không expose tùy chọn bỏ chặn qua tfvars. Mọi request còn lại được forward. Đội backend vẫn phải tắt tooling test
trong production; edge rules không thay cho bảo vệ application.

Health check mặc định `HTTP :9010 /health`, matcher `200`; không tự đổi thành
`/api/health`. Source hiện chỉ cung cấp liveness, không xác nhận readiness Firebase/
state store. Backend phải chấp nhận Host health check dạng IP:9010. Nếu thêm
readiness endpoint ở backend, cấu hình `health_check_path` tương ứng.

### C. Provision qua GITHUB ACTIONS

Tạo GitHub Environments **`uat`** và **`production`**, chỉ cho branch `main`,
reviewers theo quy trình team. Mỗi Environment có:

| Loại | Tên | Giá trị |
|---|---|---|
| Variable | `AWS_ACCOUNT_ID` | Account đã bootstrap |
| Variable | `AWS_REGION` | Region application/networking |
| Variable | `STATE_BUCKET` | Cùng bucket state hiện có |
| Variable | `AWS_ROLE_ARN` | Role UAT hoặc Production đúng từ bootstrap output |
| Secret | `APPLICATION_TFVARS` | Toàn bộ nội dung HCL tfvars của environment tương ứng |

**Triển khai:** điền backend IPs, recipients, `enable_alb=true` trong secret `APPLICATION_TFVARS`,
chạy **Application Infrastructure Terraform**, chọn environment, `operation=plan`, review rồi
`apply`. Không còn bước certificate/DNS. CloudFront + VPC origin mất ~10–15 phút.
Output `api_proxy_url` là base URL cho app mobile.
**Không đổi `enable_alb` về false sau khi đã chạy trừ khi muốn Terraform đề xuất xóa
CloudFront/ALB/monitoring/logging.** Đây không phải nút pause.

Quyền role application: state/ELB/log bucket/alarms/SNS tách theo environment;
SG/rule mutations yêu cầu tag `Environment` và `Stack` đúng environment. Tạo SG
chỉ được trong VPC mang tag `Project=commerce-casino`, `Stack=networking`. Role
không được retag SG đang có sang environment khác hoặc xóa hai tag phân quyền.
EC2/ELB describe vẫn đọc metadata trong region; các role không sửa IAM hay shared
networking. Bootstrap là nơi cập nhật những policies này.

Job chỉ chọn `uat`/`production`, dùng role và state key tương ứng. Preview và apply
là hai run, apply tạo plan mới; giữ cùng commit và input sau review. Secret không
version hóa theo commit. Environment approval nằm trước job, không sau plan mới.
Không có auto-apply hoặc auto-destroy khi push/PR.

### D. Provision bằng LOCAL — thay thế mục C

Dùng AWS session đủ quyền application và S3 state. Điền backend.hcl cùng bucket,
đúng key environment. Ví dụ UAT:

```bash
cp -n live/uat/backend.hcl.example live/uat/backend.hcl
# Điền bucket/region; key giữ uat/terraform.tfstate. Điền tfvars, enable_alb=true.
aws sts get-caller-identity
terraform -chdir=live/uat init -backend-config=backend.hcl
terraform -chdir=live/uat validate
terraform -chdir=live/uat plan -out=application.tfplan
terraform -chdir=live/uat apply application.tfplan
terraform -chdir=live/uat output api_proxy_url
```
Production làm tương tự với root `live/production` và key
`production/terraform.tfstate`; không dùng UAT state cho Production.
Không cần chạy workflow để apply lại. Nếu chuyển từ local sang Actions, đồng bộ
input/secret để tránh workflow áp lại giá trị cũ.

### E. Monitoring, logs và kiểm tra sau apply

- Mỗi env có CloudWatch dashboard: requests, healthy/unhealthy targets, ALB/backend
  5xx, backend latency p95 và target connection errors. Các dimensions được tách
  theo ALB/target group. VPN alarms/logs vẫn thuộc networking state.
- Alarms healthy targets dưới `minimum_healthy_targets`, ALB/backend 5xx, target
  connection errors và p95 latency. Ngưỡng qua tfvars, không mặc định 4 target luôn
  active. Error/latency metrics không có traffic được coi notBreaching; target
  health thiếu dữ liệu được coi breaching. Có thêm CloudFront 5xxErrorRate > 5%.
- SNS topic riêng mỗi env; **email phải nhấn Confirm subscription** mới nhận
  thông báo. Input yêu cầu recipient/action nhưng Terraform không xác nhận hộ email.
  Topic policy cho phép `cloudwatch.amazonaws.com` publish, giới hạn đúng account và
  prefix alarm của environment. Với SNS ARN bên ngoài, chủ topic phải cấp quyền
  CloudWatch tương ứng; module không sửa policy hoặc KMS key của topic bên ngoài.
- Native ALB access logs ghi **S3, không phải CloudWatch Logs**. Bucket SSE-S3,
  block public access, policy HTTPS-only, lifecycle 30 ngày UAT/90 ngày Production
  (đổi qua tfvars). Bucket logs khác bucket state; tên cố định theo convention
  `cc-ACCOUNT-REGION-ENV-api-proxy-logs` khớp IAM bootstrap.
- Không có Lambda proxy, Synthetics canary, full X-Ray hoặc log agent trên server
  khách hàng trong phạm vi này. ALB metrics không chứng minh nghiệp vụ luôn hoạt
  động; application logs/readiness và backend data consistency là phần backend.

Nghiệm thu: gọi `https://dxxxx.cloudfront.net/api/...` thành công, cả hai AZ có route
qua VPN, registered targets healthy, `/api/test/*` trả 403, docs bị chặn, auth thiếu token
bị backend từ chối ở API cần auth, email SNS đã confirm và có log S3 sau test traffic.
ALB internal không gọi được từ internet (kiểm tra bằng `curl http://<alb_dns_name>` từ ngoài VPC).
Test write→read qua các node và failover phối hợp Commerce trước go-live.

ALB có thể fail-open khi mọi target đều unhealthy; health checks không phải cơ chế
chặn tuyệt đối trong tình huống đó. Xem alarm, target health/reason codes và VPN
telemetry khi lỗi; không chỉ dựa vào status Terraform apply.

### F. Update và destroy đúng environment

Đổi input/code → plan/review/apply theo mục C hoặc D. Khi thêm quyền IAM, update
bootstrap LOCAL trước. Không dùng app root để sửa VPC/VPN.

Actions: `plan-destroy` để preview; `destroy` yêu cầu `destroy-uat` hoặc
`destroy-production` trong `destroy_confirmation`. Input sai bị chặn trước AWS auth.
Local: `terraform -chdir=live/uat plan -destroy -out=destroy.tfplan`, review rồi
`terraform -chdir=live/uat apply destroy.tfplan`; thay root đúng nếu Production.

Trước khi execute saved plan, workflow kiểm tra ALB deletion protection bằng
`scripts/check-terraform-plan.py`. Nếu plan định xóa/thay ALB đang được bảo vệ, job
dừng trước apply để tránh xóa một phần tài nguyên rồi mới vướng protection.

**Production mặc định bật ALB deletion protection.** Trước destroy cần chủ động
đặt `enable_deletion_protection=false`, giữ `enable_alb=true`, plan/review/apply
thay đổi đó trước.
**Log bucket mặc định không force-destroy**: có logs sẽ chặn xóa bucket. Giữ logs
hoặc xuất/archive theo quy trình; nếu quyết định xóa toàn bộ logs thì đặt
`force_destroy_logs=true`, plan/review/apply trước destroy. Không tự bypass các
protection trong workflow. Destroy app không xóa shared VPN/VPC/state bucket.
Destroy xóa CloudFront distribution: URL `*.cloudfront.net` mất vĩnh viễn, tạo lại sẽ ra
domain mới, nên app mobile phải đổi base URL.

### G. Kiểm tra cấu hình trước triển khai

Workflow kiểm tra account ID, region, bucket name và role ARN khớp environment trước
khi assume role. Provider được khóa bằng `.terraform.lock.hcl`; CI/deploy dùng
`init -lockfile=readonly` để không tự chọn provider mới. Khi chủ động nâng provider,
chạy `terraform init -upgrade` local, review/commit lock file rồi chạy lại CI.

Khi `enable_alb=false`/`enable_mcp=false`, output `api_proxy`/`mcp_server` là `{}` để lệnh đọc
output cuối job vẫn thành công.

Workflow CI được cấu hình validate bốn roots và chạy Terraform mock-provider tests cho các module
api-proxy/mcp-server/cloudfront-vpc-origin/network và các trạng thái bật/tắt của root env. Python tests thực thi shell workflow với Terraform giả
để kiểm tra cả hai env, bốn operations và destroy confirmation chéo environment.
Offline IAM tests evaluate chính các biểu thức policy HCL bằng Terraform, kiểm tra
state/role/resource isolation, tag-on-create và quyền CloudWatch publish SNS. Có
thêm tests thực thi validation input và kiểm tra output được lưu đúng trong state
local giả lập (không có AWS provider/tài nguyên AWS). Đây
không thay cho IAM Simulator hay kiểm thử quyền runtime trên AWS. Không dùng AWS
thật cho các tests này.

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
# Sau init -backend=false tương ứng, Terraform mock tests:
terraform -chdir=modules/api-proxy test
terraform -chdir=modules/cloudfront-vpc-origin test
terraform -chdir=modules/network test
terraform -chdir=live/uat test
terraform -chdir=live/production test
```


Kiểm chứng local: offline IAM/workflow tests có thể chạy không cần AWS. Nếu
`terraform validate`/mock tests báo provider không khởi động được vì sandbox chặn
Unix socket (`setsockopt: operation not permitted`), chưa thể coi chúng đã pass;
chạy các checks đó trên CI hoặc máy local thông thường trước apply.

Tham chiếu khi rà quyền: [EC2 security-group tag permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_ec2_securitygroups-vpc.html),
[ELBv2 IAM actions/resources](https://docs.aws.amazon.com/service-authorization/latest/reference/list_elbv2.html),
[CloudWatch → SNS policy](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Notify_Users_Alarm_Changes.html).

## MCP Server — CloudFront → ALB internal → ECS Fargate

```text
Client server Commerce / webhook Squirrel ─HTTPS─▶ CloudFront (dxxxx.cloudfront.net, cert mặc định)
  ─VPC origin─▶ ALB internal :80 (private-a + private-b) ─▶ ECS Fargate :8000 (cả UAT và Prod trên private-a + private-b)
ECS ─▶ NAT (nat-a) ─▶ Squirrel          ECS ─▶ VGW/VPN ─▶ Genesis (khi bật)
ECS ─▶ VPC endpoints / S3 gateway ─▶ ECR, Secrets Manager, CloudWatch Logs
```

Không cần domain/ACM: CloudFront phục vụ HTTPS trên `*.cloudfront.net`; ALB là internal,
không có IP public, chỉ nhận traffic từ prefix list `com.amazonaws.global.cloudfront.origin-facing`.
MCP nằm chung root `live/uat` / `live/production` với API Proxy và bật độc lập bằng `enable_mcp`.

### Chia việc giữa hai repo

| Repo | Role AWS | Làm gì |
|---|---|---|
| `cc-infra` | `cc-terraform-networking/uat/production` | Terraform: NAT, endpoints, ECR, CloudFront, ALB, ECS cluster/service/task definition, secrets (vỏ), alarms |
| `cc-mcp-server` | `cc-mcp-image-push` (branch `main`) | Build → Trivy → push ECR (tag = commit SHA, immutable) |
| `cc-mcp-server` | `cc-mcp-deploy-uat` / `cc-mcp-deploy-production` (GitHub Environment) | Register task definition mới chỉ đổi image → `update-service` → ghi `/cc/<env>/mcp/image` |

Terraform đọc image từ SSM `/cc/<env>/mcp/image` (`ignore_changes` trên value), nên apply hạ tầng
không bao giờ rollback image. Sau mỗi release, lần apply Terraform kế tiếp có thể đăng ký một
revision giống hệt và rolling restart task một lần; đó là hành vi mong đợi. Workflow mẫu:
`examples/cc-mcp-server/` (copy sang repo app; không commit tự động).

### Thứ tự triển khai lần đầu

1. **Kiểm tra AZ:** `aws ec2 describe-availability-zones --region us-east-1 --query "AvailabilityZones[].[ZoneName,ZoneId]" --output text`.
   AZ ID của `private-a`/`private-b` phải được CloudFront VPC origins hỗ trợ (đối chiếu tài liệu AWS).
2. **Bootstrap (LOCAL):** thêm `mcp_app_repository = "<owner>/cc-mcp-server"` vào bootstrap tfvars,
   plan/apply. Review: thêm policy `networking-shared-services`, 2 managed policy
   `cc-terraform-<env>-mcp-compute|operations`, 3 role `cc-mcp-*`. Không đổi bucket/OIDC provider.
3. **Networking:** thêm vào tfvars thật (và secret `NETWORKING_TFVARS`):
   `nat_subnet`, `vpc_endpoint_subnet_keys`, `ecr_repositories` (xem example). Plan phải **không có
   replace** subnet/VPN/CGW; chỉ add (NAT, EIP, endpoints, ECR, route). Contract lên v3.
4. **Image đầu tiên:** chạy workflow app (job `build`) hoặc push tay; lấy `repo@sha256:...`.
5. **Env, bước 1:** `enable_mcp = true`, `mcp_run_service = false`, `mcp_initial_image = <digest>`,
   `mcp_app_environment` (MCP_AUTH_*, SQUIRREL_BASE_URL, ...). Apply tạo CloudFront, ALB, secrets,
   cluster, task definition (chưa chạy task). CloudFront + VPC origin mất ~10–15 phút.
6. **Điền secret** (không qua Terraform, không vào state):

   ```bash
   aws secretsmanager put-secret-value --secret-id cc-mcp/uat/squirrel \
     --secret-string '{"client_id":"...","client_secret":"...","webhook_secret":"..."}'
   # Khi bật genesis: cc-mcp/uat/genesis với {"api_pass":"...","casino_id":"<mã của Commerce>"}
   ```

7. **Env, bước 2:** `mcp_run_service = true`, apply. Kiểm tra:
   `curl "$(terraform -chdir=live/uat output -raw mcp_endpoint)/readyz"`.
8. Gửi `mcp_endpoint` cho Commerce (gọi `/mcp/<name>`) và Squirrel (webhook `/webhooks/squirrel/...`);
   gửi `nat_public_ip` (output networking) nếu vendor cần allowlist IP.
9. Repo app: tạo GitHub Environments `uat`/`production` (`AWS_ROLE_ARN`, `MCP_ENDPOINT`;
   production bật required reviewers), biến repo `AWS_ACCOUNT_ID`, `AWS_IMAGE_PUSH_ROLE_ARN`.
10. Production: lặp 5–7 với **cùng digest** đã chạy ở UAT.

### Rủi ro và giới hạn đã chấp nhận

- Task ECS của cả UAT và Prod rải trên 2 AZ (private-a + private-b). Prod `mcp_min_tasks = 2` để mỗi AZ
  luôn có 1 task; UAT min 1 nên bình thường chỉ có 1 task ở 1 AZ.
- NAT và interface endpoints chỉ ở us-east-1a: task ở 1b đi chéo AZ qua 1a (thêm phí data ~$0.01/GB).
  Nếu 1a sập, task ở 1b vẫn phục vụ request nhưng không kéo được image/secret mới và không gọi được Squirrel.
- Source IP khi gọi Genesis qua VPN là `10.0.10.0/24` + `10.0.11.0/24` cho **cả hai env**; Commerce
  không phân biệt UAT/Prod theo IP.
- CloudFront default certificate cho phép TLS tối thiểu theo mặc định của CloudFront; muốn ép TLS 1.2+
  cần custom domain + ACM. Allowlist IP người gọi cần thêm WAF (chưa có).
- CloudFront không hỗ trợ điều kiện resource tag: role Terraform UAT về lý thuyết sửa được distribution
  Production. Mọi thứ khác (ECS, ALB, IAM, secrets, SSM, logs, alarms) cách ly theo tên/env.
- Role Terraform được tạo IAM role `cc-<env>-mcp-*` và PassRole cho `ecs-tasks`; đây là quyền mạnh,
  chỉ cấp cho workflow `cc-infra` trên branch `main` + GitHub Environment.
- Health check dùng `/readyz`; `/docs`, `/redoc`, `/openapi.json` bị chặn 403 ở ALB.

### Kiểm thử

```bash
terraform -chdir=modules/mcp-server test
terraform -chdir=modules/network test     # gồm tests/nat.tftest.hcl
terraform -chdir=live/uat test && terraform -chdir=live/production test
python3 -m unittest discover -s tests -p 'test_*.py' -v   # gồm MCPPolicyTests
```
