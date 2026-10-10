# Bắt đầu nhanh

Trang này đưa một máy chủ Linux mới tinh đến một bản n8n chạy HTTPS ở chế độ queue: Caddy, n8n-main, hai tiến
trình webhook, hai worker kèm task-runner sidecar riêng, Postgres 18, Valkey và sidecar backup — **mười một
container**, mọi image đều ghim theo digest. Khoảng mười lăm phút, phần lớn là chờ cài gói và kéo image.

Chọn lộ trình **A** nếu máy chủ có domain thật và chứng chỉ Let's Encrypt, lộ trình **B** nếu chạy trên laptop
hoặc máy ảo với `n8n.localtest.me` và CA nội bộ của Caddy. Chỉ bước `make init` khác nhau — lộ trình B có thêm
một bước `make trust-ca`.

!!! note "Bản tiếng Anh là bản gốc"
    Khi hai bản khác nhau, [Quickstart](quickstart.md) tiếng Anh là bản đúng. Tên biến, tên lệnh và thông báo
    lỗi được giữ nguyên tiếng Anh vì đó là những gì bạn thấy trên màn hình.

## Trước khi gõ bất cứ thứ gì

`make preflight` kiểm tra cấu hình máy, hai cổng có trống không và bản ghi DNS, và thoát với mã 1 nếu có bất kỳ
FAIL nào. Nó **không** kiểm tra bản phân phối Linux (việc đó do `scripts/bootstrap-host.sh` làm, thoát mã 2), và
nó không thể biết cổng 80/443 có tới được máy từ Internet hay không.

| Yêu cầu | Chi tiết |
|---|---|
| Cấu hình máy | 2 CPU, 3500 MB RAM, 10 GB trống ở thư mục dữ liệu của Docker. Thiếu bất kỳ mục nào, preflight báo FAIL. |
| Bản phân phối | Ubuntu 24.04 / 26.04, Debian 12 / 13, hoặc RHEL / Rocky / AlmaLinux / CentOS Stream / Oracle Linux 9 và 10. Ubuntu 24.04 LTS là bản tham chiếu. Hệ khác: tự cài Docker Engine (≥ 27), Compose plugin (≥ 2.30), `make`, `jq`, `git`, `openssl`, đặt `vm.overcommit_memory=1`, rồi bắt đầu từ bước 2. |
| DNS (lộ trình A) | Một bản ghi `A` trỏ domain về máy này. Preflight phân giải tên qua IPv4 rồi so với địa chỉ mà `api.ipify.org` trả về; lệch nhau là FAIL, vì Let's Encrypt cũng sẽ hỏng y như vậy và mỗi lần thử đều bị tính vào giới hạn. |
| Cổng mạng | 80/tcp, 443/tcp và 443/udp (HTTP/3) phải tới được máy, và không có gì khác được nghe trên 80 hoặc 443 — Caddy là container duy nhất publish cổng. Trên cloud, nhớ mở cả ba trong security group. |

Lộ trình B không cần những thứ trên: `localtest.me` và mọi tên con của nó đều phân giải về `127.0.0.1` từ bất kỳ
máy nào. Nếu không giải phóng được 80 hoặc 443, truyền `HTTP_PORT=` và `HTTPS_PORT=` cho `make init` — nhưng
thử thách HTTP-01 của ACME cần cổng 80, nên khi đó không thể xin chứng chỉ công khai.

## 1. Chuẩn bị máy chủ

```bash
curl -fsSL https://raw.githubusercontent.com/nhhandevops/n8n-prod-kit/main/scripts/bootstrap-host.sh | sudo bash -s -- --yes
```

`--yes` là bắt buộc ở dạng pipe này vì không có terminal để trả lời câu hỏi. Nếu đã clone repo,
`sudo bash scripts/bootstrap-host.sh` sẽ hỏi trước.

Script thêm kho gói chính thức của Docker, cài `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin make jq git`, đặt `vm.overcommit_memory=1` ngay và trong `/etc/sysctl.d/90-n8nkit.conf`
(Valkey cần nó), bật và khởi động `docker.service`, thêm người dùng hiện tại vào nhóm `docker`, và — trên các
máy Enterprise Linux đang chạy firewalld — mở hai service `http` và `https`. Không làm gì thêm: SELinux vẫn ở
chế độ enforcing, vì các bind mount của bộ kit đều có cờ `:z`. Chạy lần hai không đổi gì và mất khoảng một giây.
Cuối cùng script in hai khối đáng đọc: `Done on this host:` và `Deliberately NOT done:`. Mã thoát 2 nghĩa là bản
phân phối không được hỗ trợ, 3 là có gói xung đột (script in sẵn lệnh gỡ), 4 là daemon không khởi động được.

**Sau đó hãy đăng xuất rồi đăng nhập lại.** Tư cách thành viên của nhóm chỉ có hiệu lực ở phiên đăng nhập mới, và
bỏ qua bước này là lỗi đầu tiên hay gặp nhất — một phút sau `make preflight` sẽ báo `docker daemon not
reachable`. Nếu muốn ở nguyên phiên hiện tại thì dùng `newgrp docker`.

## 2. Tạo cấu hình

```bash
git clone https://github.com/nhhandevops/n8n-prod-kit && cd n8n-prod-kit/compose

# lộ trình A — máy chủ công khai
make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com

# lộ trình B — laptop hoặc máy ảo
make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443
```

`ACME_EMAIL` là bắt buộc với domain công khai (Let's Encrypt đăng ký tài khoản bằng email này và gửi cảnh báo
hết hạn), còn với tên dùng cho dev thì được điền sẵn `dev@example.com`. Mọi tên mà không CA công khai nào cấp
được — `*.localtest.me`, `*.local`, `*.test`, `*.internal`, `*.home.arpa`, `localhost`, hay một địa chỉ IPv4
trần — cũng tự chuyển `TLS_MODE` sang `internal` và `BACKUP_REMOTES` sang `/backups/local`.

`make init` chép `.env.example` thành `.env`, đặt quyền 600 **trước khi** ghi bất cứ bí mật nào vào đó, điền
domain, cổng, chế độ TLS và `PUBLIC_URL`, rồi sinh bảy bí mật: `N8N_ENCRYPTION_KEY` (64 ký tự),
`POSTGRES_PASSWORD`, `VALKEY_PASSWORD`, `N8N_RUNNERS_AUTH_TOKEN`, `GRAFANA_ADMIN_PASSWORD`,
`GRAFANA_SECRET_KEY` và `KUMA_ADMIN_PASSWORD`. Nó tạo hai cặp khoá `age` trong `secrets/` cho backup mã hoá, tự
kiểm tra lại (độ dài khoá, các bí mật đã có, quyền 600, digest đã ghim, `docker compose config` parse được) rồi
in một khối cảnh báo màu đỏ.

**Hãy làm theo khối đỏ đó ngay, đừng để lúc khác.** Hai thứ này mất là không lấy lại được:

| Cần lưu | Nằm ở đâu | Mất thì sao |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | `compose/.env` — xem bằng `grep '^N8N_ENCRYPTION_KEY=' .env` | Mọi credential lưu trong Postgres trở thành không đọc được. Một bản backup thiếu khoá này sẽ phục hồi ra một database bạn không dùng được. |
| Khoá `age` recovery | `compose/secrets/age-recovery-key.txt` | Backup mã hoá chỉ còn mở được trên chính máy này — đúng cái máy mà thảm hoạ sẽ lấy đi. |

Cho cả hai vào trình quản lý mật khẩu, rồi chạy `make detach-recovery-key`: nó in khoá recovery đúng một lần,
bắt bạn dán lại để chứng minh đã lưu đúng, rồi xoá hẳn khỏi máy. `make doctor` sẽ nhắc khi khoá nằm lại trên máy
quá bảy ngày.

Nếu máy chưa có `age-keygen` — bootstrap không cài nó — `init` sẽ build image backup của bộ kit để mượn bản
`age` bên trong, tốn thêm một lần build Docker.

## 3. Preflight

```bash
make preflight
```

Mỗi kiểm tra một dòng, chỉ đọc chứ không sửa gì, ở dạng `[ OK ]` / `[warn]` / `[FAIL] <vấn đề> — <cách sửa>`.
Cảnh báo không chặn; bất kỳ FAIL nào cũng thoát mã 1. Nó kiểm tra Docker ≥ 27 và Compose ≥ 2.30, quyền và các
khoá bắt buộc trong `.env`, digest đã ghim, cổng HTTP và HTTPS (có nêu tên tiến trình và PID đang giữ cổng),
dung lượng đĩa, RAM, số CPU, đồng bộ đồng hồ, `vm.overcommit_memory`, cấu hình backup và DNS.

`make up` tự chạy preflight trước khi kéo image, nên bước này không bắt buộc — nhưng chạy riêng chỉ mất vài giây
và phát hiện bản ghi DNS sai trước khi bạn ngồi chờ kéo image.

## 4. Khởi động stack

```bash
make up
```

Thứ tự: preflight, kiểm tra khoá phiên bản, `render` (sinh các mảnh Compose và target Prometheus), `pull` mọi
image đã ghim, build image backup tại chỗ, sửa quyền cho volume backup, xuất CA dev ở lộ trình B,
`docker compose up -d --wait` với hạn 900 giây, sửa quyền sở hữu `n8n_files`, nạp lại cấu hình Caddy, cài đặt
Kuma và Grafana nếu bật profile tương ứng, rồi in bảng trạng thái.

Kéo image và chạy migration lần đầu là hai phần chậm, và cả hai chỉ xảy ra một lần. CI đo `init` + `up` +
`doctor` hết 171 giây trên runner của GitHub; trên một máy ảo đang tải nặng, lần khởi động đầu mất 6,5 phút,
trong đó 2 phút 41 giây là migration (275 migration ở phiên bản đã đo). Vì vậy health check của `n8n-main` có
`start_period` 600 giây và `up` chờ tới 900 giây. Trong lúc đó `make logs SERVICE=n8n-main` sẽ hiện các dòng
`Starting migration …`. Việc pull được thử lại ba lần, cách nhau 20 rồi 40 giây, vì registry công khai bóp băng
thông client ẩn danh: gặp `toomanyrequests` ở lần đầu là bình thường, không phải lỗi chết.

Caddy khởi động trước khi n8n sẵn sàng và trả 502 cho tới khi `/healthz/readiness` pass. Đó là cố ý — 502 là
trung thực, trong khi một n8n đang khởi động trả HTTP 200 cho **mọi** đường dẫn và sẽ nhận một webhook mà nó
không bao giờ chạy.

## 5. Xác nhận đã chạy

```bash
make status
```

Một bảng `SERVICE  STATE  HEALTH  UP  RESTARTS` cho từng service trong cấu hình đã resolve, rồi:

```text
[ OK ] all 11 services running and healthy
  n8n:  https://n8n.example.com/
```

Lệnh thoát mã 1 nếu có service nào không `running` và `healthy`, đồng thời nêu tên service cần xem bằng
`make logs SERVICE=<tên> SINCE=10m`. Ở lộ trình B nó còn nhắc rằng chứng chỉ đến từ CA nội bộ của bộ kit.

## 6. Tạo tài khoản owner

Mở URL mà `make status` vừa in. n8n hiện trang thiết lập lần đầu, và tài khoản bạn tạo ở đó là owner của
instance. Mật khẩu cần tối thiểu tám ký tự, có một chữ số và một chữ hoa. Thiết lập chỉ diễn ra một lần — lần
thứ hai sẽ nhận `400 Instance owner already setup`.

Hãy làm việc này **trước** `make smoke`, vì smoke sẽ tự tạo owner nếu instance chưa có
(`smoke-owner@example.com`, mật khẩu nằm trong `compose/.smoke/owner.env`) và khi đó trang thiết lập biến mất.

Khi đã có owner, bài kiểm tra đầu-cuối tuỳ chọn là `make smoke`: sức khoẻ dịch vụ, chuyển hướng HTTP→HTTPS,
chuỗi chứng chỉ và các security header, owner/đăng nhập/API key, một webhook do pool trả lời chứ không phải
main, một execution thật chạy trên worker kèm Code node, metrics, rồi một lần backup và một lần kiểm tra khôi
phục. Bài test idempotent và tự xoá các workflow nó tạo ra. Suite chạy lần lượt và dừng ở lỗi đầu tiên, nên trên
một bản cài lộ trình A mới tinh nó sẽ chạy tới `07-backup` rồi dừng: `BACKUP_REMOTES` vẫn còn trống. Lộ trình B
pass hết, vì `init` đã đặt `BACKUP_REMOTES=/backups/local` cho domain dev.

## Lộ trình B: tin tưởng CA dev

Với `TLS_MODE=internal`, Caddy tự tạo CA riêng và cấp chứng chỉ có hạn 12 giờ. `make up` chỉ xuất chứng chỉ gốc
ra `compose/secrets/dev-root.crt` — không bao giờ xuất khoá riêng của CA — và mount nó vào mọi tiến trình n8n
qua `NODE_EXTRA_CA_CERTS`, để n8n gọi được chính `PUBLIC_URL` của nó. Trình duyệt và `curl` vẫn cần được báo:

```bash
make trust-ca
```

Lệnh làm gì còn tuỳ nơi bạn chạy, nên hãy đọc output thay vì đoán. Nó luôn chép chứng chỉ ra `~/n8nkit-root.crt`,
và nếu chạy dưới WSL thì chép thêm vào thư mục `Downloads` của Windows. Ngoài ra:

- Trên chính máy đó, nó cài vào kho tin cậy hệ thống bằng `update-ca-certificates` (Debian, Ubuntu) hoặc
  `update-ca-trust` (họ RHEL). Nó nâng quyền bằng `sudo -n`, vốn không bao giờ hỏi mật khẩu, nên nếu `sudo` của
  bạn đòi mật khẩu thì lệnh in `not installed into the host trust store` và gợi ý dùng `curl --cacert <đường dẫn>`.
- Nếu trình duyệt nằm trên **máy khác**, lệnh in sẵn những dòng bạn cần: một lệnh `scp` để lấy chứng chỉ và
  `certutil -addstore -f ROOT` cho PowerShell quyền administrator trên Windows, kèm lệnh `security
  add-trusted-cert` tương đương cho macOS. URL để mở được in ở giữa, sau phần Windows và trước phần macOS.

Vì `localtest.me` phân giải về `127.0.0.1` ở mọi nơi, trình duyệt phải chạy trên chính máy đang chạy stack. Từ
máy khác thì cần SSH port forward hoặc một dòng trong file hosts của máy đó — bộ kit không tự làm hộ việc này.

## Đã chạy rồi — giờ làm gì

Chạy `make doctor`. Đây là bản chẩn đoán nên dán vào báo cáo lỗi: khoá phiên bản, sức khoẻ từng service kèm 20
dòng log cuối của bất kỳ service nào không khoẻ, cổng, DNS, hạn chứng chỉ, đĩa, Postgres, Valkey và backup. Trên
một bản cài công khai mới tinh, nó báo đúng một FAIL — `BACKUP_REMOTES is empty` — và nó báo đúng. Xử lý việc đó
là nhiệm vụ tiếp theo.

| Tiếp theo | Ở đâu |
|---|---|
| Một đích backup ngoài máy chủ, và một lần khôi phục bạn đã thực sự thử | [Backup and restore](operations/backup-restore.md) |
| Prometheus, Grafana, Loki và cảnh báo (`COMPOSE_PROFILES=monitoring`) | [Monitoring](operations/monitoring.md) |
| Lên phiên bản n8n mới, và cách quay lại | [Upgrade and rollback](operations/upgrade-rollback.md) |
| Mất một worker, Valkey sập hay main khởi động lại thì thực sự mất gì | [Chaos drills](operations/chaos-drills.md) |
| SELinux, firewalld và đường cài bằng dnf | [RHEL-family hosts](operations/rhel-hosts.md) |

`make help` liệt kê mọi target. `make scale-workers N=4` đặt số worker (1 đến 16, mỗi worker có sidecar runner
riêng). `UI_PROTECT=on` cùng `UI_ALLOW_CIDR='203.0.113.0/24'` đặt một danh sách IP cho phép và basic auth trước
editor và API, trong khi webhook, form và endpoint MCP vẫn mở; `.env.example` giải thích từng thiết lập, kể cả
lý do chuỗi hash bcrypt phải đặt trong nháy đơn. Khi báo lỗi, `make env-keys` in **tên** các khoá trong `.env` —
không bao giờ in nội dung file.

## Khi một bước thất bại

Mọi thông báo dưới đây đều đã gặp trên máy thật. Output của script đi ra stderr, nên thêm `2>&1` nếu bạn muốn giữ lại.

| Thông báo | Nghĩa là gì và làm gì |
|---|---|
| `docker daemon not reachable — is … in the docker group?` | Chưa có phiên đăng nhập mới kể từ khi bootstrap thêm bạn vào nhóm `docker`. Đăng xuất rồi đăng nhập lại, hoặc `newgrp docker`. |
| `port 443 is in use by <process> (pid N)` | Thứ khác đang giữ cổng mà Caddy cần publish. Dừng nó, hoặc đặt `HTTP_PORT`/`HTTPS_PORT` trong `.env` rồi chạy lại `make up` — `make init` từ chối ghi đè `.env` đã tồn tại (thoát mã 2). |
| `DNS: … but this host's public IP is …` | Bản ghi trỏ sai chỗ, và mỗi lần Let's Encrypt xác thực hỏng đều bị tính. Sửa bản ghi; trong lúc thử nghiệm, `TLS_MODE=acme-staging` chạy đúng luồng đó với CA staging, không giới hạn như bản production (chứng chỉ không được tin cậy, và điều đó là cố ý). |
| `.env already exists — nothing changed` (thoát mã 2) | `init` không bao giờ ghi đè bí mật. Hãy sửa trực tiếp `.env`; `FORCE=1` sinh lại mọi bí mật trong `.env`, kể cả khoá mã hoá, khiến credential hiện có không đọc được nữa; các khoá `age` trong `secrets/` được giữ nguyên nên backup cũ vẫn giải mã được. |
| `versions.env has unpinned images — run: make pin` | Thiếu một digest; `make pin` sẽ ghi chúng. Trên một bản đang chạy, hãy đổi phiên bản n8n bằng `make upgrade`, đừng dùng `make pin` rồi `make up`. |
| `image pull failed — retrying in 20 s` | Giới hạn tốc độ của registry với client ẩn danh; nó tự thử lại ba lần. `versions.env` có ghi các mirror phục vụ cùng digest. |
| `n8n-main` kẹt ở trạng thái `starting` vài phút | Lần khởi động đầu chạy toàn bộ migration. Xem `make logs SERVICE=n8n-main`; `up` cho phép tới 900 giây. |
| Editor trả HTTP 502 ngay sau `make up` | Caddy đã lên, n8n thì chưa sẵn sàng. Chờ `make status` báo `healthy`. |
| Nhận `429` kèm header `Retry-After` khi đăng nhập | n8n giới hạn `/rest/login` năm lần mỗi chu kỳ cho mỗi IP, và không cấu hình được. Chờ hết chu kỳ. |
| Caddy ghi log `Import file is empty` | `tls-acme.caddy` trống là cố ý: không có chỉ thị `tls` nghĩa là Caddy dùng cơ chế Let's Encrypt mặc định. Đây là cảnh báo, không phải lỗi. |
| Một script chạy qua SSH dừng im lặng ở `make up` | `make up` và `docker compose up` đọc stdin và nuốt luôn phần còn lại của script. Hãy chép script sang máy đó và chạy dạng file với `</dev/null`. |
| Node Read/Write Files lỗi quyền truy cập | Volume `n8n_files` có từ trước khi bộ kit chown điểm mount của nó. Chạy lại `make up` — `files-perms.sh` sửa tại chỗ, không cần khởi động lại. |

Nếu lỗi của bạn không có trong bảng, thứ mà một báo cáo lỗi cần là `make doctor` và `make env-keys`. Bản ghi
chép các lỗi upstream đã được xác minh, kèm nguồn, nằm trong `warning_bug_and_solutions.md`.
