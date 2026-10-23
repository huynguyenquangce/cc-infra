# cc-infra — networking / VPN trước

Terraform cho AWS Commerce Casino, dựa trên `CLAUDE.md`, `huy-knowledge.md` và
`codex-knowledge.md` ở workspace cha. Hiện chỉ có bootstrap và networking/VPN.
Chưa tạo application, ECS, Lambda, ALB hay môi trường staging/prod.

## State và cấu trúc

| Root | S3 key | Quản lý |
|---|---|---|
| `bootstrap/` | `bootstrap/terraform.tfstate` | S3 state bucket, GitHub OIDC provider, IAM role networking |
| `live/networking/` | `networking/terraform.tfstate` | VPC, private subnets, route tables, VGW, CGW, VPN, logs/alarms, SSM contract |
| Tương lai: `live/staging/` | `staging/terraform.tfstate` | Application staging/UAT |
| Tương lai: `live/prod/` | `prod/terraform.tfstate` | Application production |

**Hiện 2 state; sau này 3 state hạ tầng/application + 1 state bootstrap = 4 state.**
Dùng chung một bucket, tách key và IAM permission. Không dùng Terraform workspace
để chuyển môi trường. `staging` sẽ tương ứng UAT trong tài liệu thiết kế.

```text
modules/
  state-backend/    # S3 versioning, SSE-S3 encryption, block public access, HTTPS-only
  github-oidc/      # Exact repository + environment trust, dedicated role/policies
  network/          # Shared VPC, private subnets, route table per subnet
  vpn/              # VGW + BGP, configurable customer endpoints, two tunnels/connection
bootstrap/
live/networking/
.github/workflows/  # Validation without AWS; manual networking plan/apply with OIDC
```

VGW + BGP là phương án ban đầu cho một VPC dùng chung, cần xác nhận với đội network.
Hai subnet private là phân bổ đề xuất để kiểm tra VPN và mở rộng sau này.
Networking phase chưa tạo NAT/Internet Gateway/VPC endpoints; subnet chưa có internet
egress. Chưa có workload để kiểm thử application traffic. Default VPC security group
và NACL do AWS tạo; SG cụ thể cho workload sẽ làm cùng application.

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
nếu bootstrap từ máy khác platform. Lock file chưa được tạo trong lần authoring này
vì máy chưa có Terraform và không truy cập được registry/release qua shell.

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

Sau này thêm `live/staging` và `live/prod`, mỗi root dùng S3 key riêng; đọc SSM contract
bằng data source và chọn subnet được phân bổ cho env đó. Networking tiếp tục sở hữu
VPC/subnet/routes/VPN; application sở hữu ALB/ECS/Lambda/SG. Không khai báo một resource
ở hai state. Tạo IAM roles/policies và mở rộng workflows theo phạm vi application
khi bắt đầu phase đó. Có thể thêm subnet dành riêng mỗi env vào networking trước.

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
