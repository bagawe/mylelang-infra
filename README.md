# mylelang-infra

Deployment/orchestration for **My Lelang** on a single development VPS
(8 GB RAM / 8 vCPU). Images are **built on the VPS** (no container registry);
Caddy terminates TLS; Postgres, Redis, MinIO and ClamAV run self-hosted in the
same Compose stack.

**Dev domains (current):**


| Hostname                      | Service         |
| ----------------------------- | --------------- |
| `https://dev.mylelang.id`     | Web (Next.js)   |
| `https://api.dev.mylelang.id` | API + WebSocket |


---

## Stack


| Service                           | Role                                   | Notes                                 |
| --------------------------------- | -------------------------------------- | ------------------------------------- |
| `caddy`                           | Reverse proxy + auto HTTPS             | `dev.*` → web, `api.dev.*` → api      |
| `web`                             | Next.js 16 (standalone)                | `NEXT_PUBLIC_*` baked at build time   |
| `api`                             | NestJS API (`:3000`, prefix `/api/v1`) | `NODE_ENV=development`                |
| `worker`                          | BullMQ consumer                        | email outbox, upload scan pipeline    |
| `postgres`                        | PostgreSQL 16                          | volume `pgdata`; host `:5432` → Tailscale only |
| `redis`                           | Redis 7 (AOF)                          | volume `redisdata`; not published on host |
| `minio`                           | S3-compatible storage                  | host `:9000`/`:9001` → Tailscale only |
| `clamav`                          | Virus scan for private uploads         | ~2 GB RAM; cold start several minutes |
| `migrate` / `seed` / `minio-init` | one-shot tools (profile `tools`)       | run on demand                         |


Worker uses `CLAMD_HOST=clamav` / `CLAMD_PORT=3310` (Compose DNS). ClamAV is
not published on the host. Keep ~4 GB swap — ClamAV + `docker compose build`
can spike memory on an 8 GB box.

---



## On-disk layout (VPS)

```
/opt/mylelang/
├── mylelang-infra/     # this repo (main)
├── mylelangbackend/    # backend (main)
└── mylelangweb/        # web (main)
```

---



## End-to-end setup (from zero)

Ikuti berurutan. Bagian A–B (DNS) bisa dikerjakan sebelum/bersamaan dengan VPS.

**Alur VPS yang disarankan:** install `git` sebentar → clone **mylelang-infra** dulu →
jalankan `scripts/bootstrap-vps.sh` (otomatis Docker/swap/firewall) → clone app →
`deploy.sh`.

### A. Domain: Hostinger → Cloudflare

Domain dibeli di Hostinger; DNS dikelola di Cloudflare.

1. Login [Cloudflare](https://dash.cloudflare.com) → **Add a site** → `mylelang.id` → plan **Free**.
2. Catat **2 nameserver** yang diberikan Cloudflare (contoh `ada.ns.cloudflare.com` / `bob.ns.cloudflare.com`).
3. Login Hostinger → **Domains** → `mylelang.id` → **Nameservers** → **Custom nameservers** → isi 2 NS Cloudflare → simpan.
4. Tunggu status domain di Cloudflare jadi **Active** (bisa 15 menit–24 jam).

Cek:

```sh
dig NS mylelang.id +short
```

Harus menampilkan nameserver Cloudflare.

### B. DNS records (Cloudflare)

Setelah Active, **DNS → Records** → tambah (Proxy = **DNS only** / abu-abu):


| Type | Name      | Content    | Proxy    |
| ---- | --------- | ---------- | -------- |
| `A`  | `dev`     | `<IP_VPS>` | DNS only |
| `A`  | `api.dev` | `<IP_VPS>` | DNS only |


Hasil FQDN: `dev.mylelang.id` dan `api.dev.mylelang.id`.

Cek:

```sh
dig +short dev.mylelang.id
dig +short api.dev.mylelang.id
```

Keduanya harus = IP VPS. **Jangan** aktifkan proxy oranye dulu sampai HTTPS Caddy berhasil.

### C. VPS kosong → clone infra → bootstrap script

Asumsi: VPS baru **Ubuntu** (22.04/24.04) atau Debian. User punya `sudo`.

Yang diotomasi `scripts/bootstrap-vps.sh`:

- apt update/upgrade + tool dasar (`git`, `curl`, `ufw`, …)
- Docker CE resmi + Compose plugin
- `systemctl enable --now docker` + user masuk group `docker`
- swap 4 GB
- firewall (OpenSSH + 80 + 443; **bukan** 5432/9000/9001)
- folder `/opt/mylelang`



#### C1. Install git saja (satu-satunya langkah manual awal)

```sh
sudo apt-get update
sudo apt-get install -y git
```



#### C2. Clone **mylelang-infra** dulu

```sh
sudo mkdir -p /opt/mylelang
sudo chown "$USER:$USER" /opt/mylelang
cd /opt/mylelang
git clone <URL_REPO_INFRA> mylelang-infra
cd mylelang-infra
git checkout main
```



#### C3. Jalankan bootstrap

```sh
chmod +x scripts/*.sh
sudo ./scripts/bootstrap-vps.sh
```

Lalu **logout SSH dan login lagi**, verifikasi:

```sh
docker ps
docker compose version
free -h
sudo ufw status
```

Script idempotent (aman dijalankan ulang). Isi detail ada di `scripts/bootstrap-vps.sh`.

### D. Clone backend + web

Infra sudah di-clone di langkah C. Sekarang clone app.
**Wajib pakai SSH** (bukan HTTPS) supaya `deploy.sh` / GitHub Actions bisa
`git pull` tanpa prompt password. Setup key: lihat
[VPS ↔ GitHub SSH](#vps--github-ssh-wajib-untuk-actions--deploysh) di bawah.

```sh
cd /opt/mylelang
# Ganti bagawe jika owner GitHub-mu berbeda
git clone git@github.com:bagawe/mylelangbackend.git mylelangbackend
git clone git@github.com:bagawe/mylelangweb.git mylelangweb

git -C mylelangbackend checkout main
git -C mylelangweb checkout main
```

Layout akhir di VPS (nama **folder**):

```
/opt/mylelang/mylelang-infra
/opt/mylelang/mylelangbackend
/opt/mylelang/mylelangweb
```

Nama **repo GitHub** harus sama dengan yang di remote (jangan typo
`mylelang-nfra`). Folder lokal boleh di-rename dengan `mv`; remote diubah
dengan `git remote set-url`.

### E. Buat `env/dev.env`

**Opsi 1 (disarankan):** copy file yang sudah di-generate di laptop
(`mylelang-infra/env/dev.env`, gitignored):

```sh
# dari laptop
scp /path/ke/mylelang-infra/env/dev.env USER@IP_VPS:/opt/mylelang/mylelang-infra/env/dev.env

# di VPS
chmod 600 /opt/mylelang/mylelang-infra/env/dev.env
```

**Opsi 2:** buat dari contoh di VPS:

```sh
cd /opt/mylelang/mylelang-infra
cp env/dev.env.example env/dev.env
chmod 600 env/dev.env
```

Isi minimal yang wajib diganti (sudah sesuai domain jika pakai opsi 1):

```env
APP_DOMAIN=dev.mylelang.id
API_DOMAIN=api.dev.mylelang.id
CADDY_EMAIL=admin@mylelang.id

NEXT_PUBLIC_APP_URL=https://dev.mylelang.id
NEXT_PUBLIC_API_BASE_URL=https://dev.mylelang.id/api/v1
NEXT_PUBLIC_WS_URL=https://api.dev.mylelang.id
CORS_ORIGINS=https://dev.mylelang.id

POSTGRES_PASSWORD=<password-kuat>
DATABASE_URL=postgresql://mylelang:<password-kuat>@postgres:5432/mylelang?schema=public

OBJECT_STORAGE_SECRET_KEY=<password-kuat-minio>

# Generate 4x terpisah: openssl rand -hex 32
ACTIVATION_TOKEN_ENCRYPTION_KEY=<64-hex>
MFA_ENCRYPTION_KEY=<64-hex>
IDENTITY_ENCRYPTION_KEY=<64-hex>
BANK_ACCOUNT_ENCRYPTION_KEY=<64-hex>
```

`API_KEY` boleh placeholder dulu; di-mint setelah stack naik (langkah G).

Wajib ada `TAILSCALE_IP` (lihat [Tailscale](#tailscale-akses-postgres--minio)):

```env
# Sementara aman (hanya localhost VPS) sampai Tailscale terpasang:
TAILSCALE_IP=127.0.0.1
```

Backup 4 encryption key di luar VPS. Kalau hilang, data terenkripsi tidak bisa dibaca.

### F. First deploy

```sh
cd /opt/mylelang/mylelang-infra
chmod +x scripts/*.sh
./scripts/deploy.sh
```

Script ini: `git pull` 3 repo → `docker compose build` → up datastore (+ ClamAV) → `minio-init` → `migrate` → up semua service.

**ClamAV** cold start bisa beberapa menit. Cek:

```sh
docker compose --env-file env/dev.env ps
docker compose --env-file env/dev.env logs clamav --tail 50
```

Seed data pertama kali (regions + synthetic):

```sh
docker compose --env-file env/dev.env run --rm seed
```



### G. Mint service key untuk web BFF

```sh
cd /opt/mylelang/mylelang-infra
docker compose --env-file env/dev.env run --rm api \
  npm run service-client -- create web-bff-dev 30
```

Salin key `mlk_...` ke `env/dev.env` → `API_KEY=...`, lalu rebuild/restart web:

```sh
./scripts/deploy.sh
```



### H. Verifikasi

```sh
curl -I https://dev.mylelang.id
curl -s https://api.dev.mylelang.id/api/v1/health/live
curl -s https://api.dev.mylelang.id/api/v1/health/ready

docker compose --env-file env/dev.env logs caddy --tail 80
```

Browser: buka `https://dev.mylelang.id`.

### I. Backup cron (sekali)

```sh
sudo touch /var/log/mylelang-pg-backup.log
sudo chown "$USER" /var/log/mylelang-pg-backup.log
crontab -e
# tambahkan:
# 0 2 * * * /opt/mylelang/mylelang-infra/scripts/pg-backup.sh >> /var/log/mylelang-pg-backup.log 2>&1
```



### J. GitHub Actions auto-deploy (opsional tapi disarankan)

Di repo **mylelangbackend** dan **mylelangweb** → **Settings → Secrets and variables → Actions**, buat:


| Secret         | Isi                               |
| -------------- | --------------------------------- |
| `DEV_SSH_HOST` | IP VPS                            |
| `DEV_SSH_USER` | user SSH (anggota group `docker`) |
| `DEV_SSH_KEY`  | private key PEM user itu          |
| `DEV_SSH_PORT` | `22` (atau port SSH custom)       |


Workflow: push ke branch `main` → SSH ke VPS → jalankan `scripts/deploy.sh`.

Pastikan public key pasangan `DEV_SSH_KEY` sudah ada di `~/.ssh/authorized_keys` di VPS.

Cek user SSH yang masuk group docker (nilai `DEV_SSH_USER`):

```sh
whoami          # contoh: mylelangserver
groups          # harus memuat: docker
docker ps       # harus sukses tanpa sudo
```

Sebelum Actions bisa `git pull` di VPS, selesaikan bagian
[VPS ↔ GitHub SSH](#vps--github-ssh-wajib-untuk-actions--deploysh) di bawah.

**SSH tetap publik (hybrid):** Actions SSH ke IP publik VPS. Jangan kunci
port 22 hanya ke Tailscale — itu memutus GitHub-hosted runners. Postgres/MinIO
sudah dilindungi lewat bind Tailscale (bukan lewat UFW SSH).

---

## Tailscale (akses Postgres / MinIO)

Ikuti **berurutan** di bawah. Asumsi stack My Lelang sudah pernah jalan
(§A–J). Kalau belum, selesaikan first deploy dulu; bagian ini bisa digabung
saat menyiapkan `env/dev.env`.

### Model akses (ingat ini)

| Surface | Publik? | Catatan |
| --- | --- | --- |
| `80` / `443` (Caddy → web/api) | Ya | Domain Cloudflare |
| `22` SSH | Ya (key-only) | Actions butuh IP publik; manusia boleh lewat Tailscale |
| Postgres `5432` | **Tidak** | Hanya IP Tailscale (atau sementara `127.0.0.1`) |
| MinIO `9000` / console `9001` | **Tidak** | Sama |
| Redis / ClamAV | Tidak | Hanya jaringan Compose internal |

App di dalam Docker **tetap** memakai hostname Compose (`postgres`, `minio`).
`DATABASE_URL` dan `OBJECT_STORAGE_ENDPOINT` **jangan** diganti ke IP Tailscale.

---

### Langkah 0 — Pull perubahan infra di VPS

Di laptop, commit/push `mylelang-infra` yang berisi bind Tailscale, lalu di VPS:

```sh
cd /opt/mylelang/mylelang-infra
git fetch
git checkout main
git pull --ff-only
```

Pastikan file ini ada di VPS:

- `compose.yaml` (ada `ports: "${TAILSCALE_IP}:5432:5432"` dll.)
- `env/dev.env.example` (ada baris `TAILSCALE_IP=...`)

---

### Langkah 1 — Pastikan `TAILSCALE_IP` di `env/dev.env` (VPS)

```sh
cd /opt/mylelang/mylelang-infra
grep TAILSCALE_IP env/dev.env || true
```

Kalau belum ada, tambahkan (aman sementara — hanya listen di localhost VPS):

```sh
# jika baris belum ada:
echo 'TAILSCALE_IP=127.0.0.1' >> env/dev.env
```

Atau edit manual:

```env
TAILSCALE_IP=127.0.0.1
```

**Jangan** biarkan kosong / hapus key ini — Docker bisa bind ke `0.0.0.0`
(terbuka ke internet).

---

### Langkah 2 — Apply publish port (masih localhost) di VPS

Volume data **tidak** hilang. Hanya mapping port yang berubah.

```sh
cd /opt/mylelang/mylelang-infra
docker compose --env-file env/dev.env up -d postgres minio
```

Cek:

```sh
ss -lntup | grep -E '5432|9000|9001'
# diharapkan sementara: 127.0.0.1:5432 / 127.0.0.1:9000 / 127.0.0.1:9001
# BUKAN 0.0.0.0:...
```

Dari laptop **belum** bisa connect ke DB/MinIO — normal. Lanjut install
Tailscale.

---

### Langkah 3 — Install & login Tailscale di VPS

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Terminal akan menampilkan URL login, contoh:

```text
To authenticate, visit:
  https://login.tailscale.com/a/........
```

Buka URL itu di browser (boleh dari laptop) → login akun Tailscale
(Google/Microsoft/GitHub/email) → **Connect**.

Verifikasi di VPS:

```sh
tailscale status
tailscale ip -4
```

Contoh output IP: `100.91.23.45` — **catat** angka ini (disebut `TS_IP`
di langkah berikutnya).

MagicDNS (opsional, enak dipakai):

```sh
tailscale status --json | head   # atau lihat di admin console
# hostname sering seperti: mylelangserver   →  mylelangserver.tailnet-xxxx.ts.net
```

Di [admin console](https://login.tailscale.com/admin/machines) pastikan
machine VPS status **Connected**.

---

### Langkah 4 — Install & login Tailscale di laptop

1. Download: [https://tailscale.com/download](https://tailscale.com/download)
   - macOS: App Store atau `.pkg`
   - Windows / Linux: ikuti halaman download
2. Buka app Tailscale → **Log in** → **akun yang sama** dengan VPS
   (atau akun dalam Tailnet/org yang sama).
3. Menu bar (macOS) / system tray: status harus **Connected**.
4. Di admin console, pastikan laptop juga muncul sebagai machine **Connected**.

Tes dari **laptop** (ganti `100.91.23.45` dengan `TS_IP` VPS):

```sh
ping -c 3 100.91.23.45
```

Harus ada reply. Kalau timeout:

- Tailscale di VPS & laptop sama-sama Connected?
- Kedua device di tailnet yang sama (cek admin console)?
- Firewall lokal laptop memblok ICMP? Coba `nc -vz 100.91.23.45 22` sebagai
  tes alternatif.

Opsional SSH ke VPS lewat Tailscale (manusia; Actions tetap pakai IP publik):

```sh
ssh USER@100.91.23.45
# atau MagicDNS:
ssh USER@mylelangserver.tailnet-xxxx.ts.net
```

---

### Langkah 5 — Pindahkan publish Postgres/MinIO ke IP Tailscale (VPS)

Masih di VPS:

```sh
cd /opt/mylelang/mylelang-infra

# ganti 100.91.23.45 dengan hasil `tailscale ip -4`
# macOS/BSD sed beda; di Ubuntu VPS:
sed -i 's/^TAILSCALE_IP=.*/TAILSCALE_IP=100.91.23.45/' env/dev.env

grep '^TAILSCALE_IP=' env/dev.env
```

Recreate mapping port:

```sh
docker compose --env-file env/dev.env up -d postgres minio
```

Verifikasi listen di IP Tailscale:

```sh
ss -lntup | grep -E '5432|9000|9001'
# diharapkan:
#   100.91.23.45:5432
#   100.91.23.45:9000
#   100.91.23.45:9001
# BUKAN 0.0.0.0 dan bukan hanya 127.0.0.1
```

Cek cepat dari VPS sendiri (harus OK):

```sh
# ganti password dari env/dev.env
docker compose --env-file env/dev.env exec -T postgres \
  pg_isready -U mylelang -d mylelang
```

---

### Langkah 6 — Ambil kredensial (sekali, aman)

Dari VPS (atau salin dari `env/dev.env` lokal yang sudah di-scp):

```sh
grep -E '^(POSTGRES_|OBJECT_STORAGE_)' /opt/mylelang/mylelang-infra/env/dev.env
```

Yang dibutuhkan di laptop:

| Kebutuhan | Key di `dev.env` |
| --- | --- |
| Postgres user | `POSTGRES_USER` |
| Postgres password | `POSTGRES_PASSWORD` |
| Postgres database | `POSTGRES_DB` |
| MinIO user | `OBJECT_STORAGE_ACCESS_KEY` |
| MinIO password | `OBJECT_STORAGE_SECRET_KEY` |

---

### Langkah 7 — Konfigurasi client di laptop

Ganti `100.91.23.45` dengan `TS_IP` VPS. Pastikan Tailscale laptop **Connected**.

#### 7a. Postgres — `psql` (CLI)

```sh
# macOS: brew install libpq && brew link --force libpq
psql "postgresql://mylelang:<POSTGRES_PASSWORD>@100.91.23.45:5432/mylelang"
```

Tes: `\conninfo` lalu `\dt` atau `SELECT 1;`.

#### 7b. Postgres — TablePlus / DBeaver / DataGrip

| Field | Nilai |
| --- | --- |
| Type | PostgreSQL |
| Host | `100.91.23.45` |
| Port | `5432` |
| User | `mylelang` (atau `POSTGRES_USER`) |
| Password | isi `POSTGRES_PASSWORD` |
| Database | `mylelang` (atau `POSTGRES_DB`) |
| SSL | Off (dev di Tailscale private) |

#### 7c. MinIO Console (browser)

1. Pastikan Tailscale Connected.
2. Buka: `http://100.91.23.45:9001`
3. Login:
   - Access Key = `OBJECT_STORAGE_ACCESS_KEY`
   - Secret Key = `OBJECT_STORAGE_SECRET_KEY`
4. Bucket `mylelang-uploads` harus terlihat (dibuat `minio-init`).

#### 7d. MinIO S3 API (opsional, `mc` / SDK)

```sh
# contoh dengan mc (kalau terpasang di laptop)
mc alias set mylelang-dev http://100.91.23.45:9000 \
  '<OBJECT_STORAGE_ACCESS_KEY>' '<OBJECT_STORAGE_SECRET_KEY>'
mc ls mylelang-dev/mylelang-uploads
```

#### 7e. SSH via Tailscale (opsional, manusia)

Simpan di `~/.ssh/config` laptop:

```sshconfig
Host mylelang-dev
  HostName 100.91.23.45
  User mylelangserver
  IdentityFile ~/.ssh/id_ed25519
```

Lalu: `ssh mylelang-dev`.

**GitHub Actions** tetap pakai Secret `DEV_SSH_HOST` = **IP publik** VPS
(bukan IP Tailscale).

---

### Langkah 8 — Checklist akhir

| # | Cek | Di mana |
| --- | --- | --- |
| 1 | `tailscale status` Connected | VPS + laptop |
| 2 | `ping TS_IP` sukses | laptop → VPS |
| 3 | `grep TAILSCALE_IP env/dev.env` = IP `100.…` | VPS |
| 4 | `ss` listen di `100.…:5432/9000/9001` | VPS |
| 5 | `psql` / TablePlus connect | laptop |
| 6 | Browser MinIO console login | laptop |
| 7 | `https://dev.mylelang.id` masih OK | publik |
| 8 | Actions deploy masih hijau (SSH IP publik) | GitHub |

---

### Troubleshooting Tailscale

| Gejala | Perbaikan |
| --- | --- |
| `ping` timeout | Kedua device Connected? Akun/tailnet sama? |
| `psql: connection refused` | `TAILSCALE_IP` belum di-set ke IP Tailscale, atau belum `compose up -d postgres minio` |
| `ss` masih `127.0.0.1` | Langkah 5 belum dijalankan |
| `ss` = `0.0.0.0:5432` | `TAILSCALE_IP` kosong — set segera + recreate |
| MinIO console blank / timeout | Pakai `http://` (bukan https) ke `:9001`; Tailscale Connected? |
| App web/API error DB | Jangan ubah `DATABASE_URL` ke IP Tailscale — biarkan `@postgres:5432` |
| Actions SSH gagal setelah Tailscale | Jangan kunci UFW OpenSSH; `DEV_SSH_HOST` harus IP publik |

---

### Upgrade opsional nanti (1A ketat)

Kalau ingin SSH hanya via Tailscale: pasang
[Tailscale GitHub Action](https://github.com/tailscale/github-action) + auth
key di workflow, lalu SSH ke MagicDNS/IP Tailscale VPS, baru kunci UFW SSH.
Untuk sekarang **jangan** — hybrid lebih sederhana dan Actions tetap jalan.

---

## VPS ↔ GitHub SSH (wajib untuk Actions / deploy.sh)

Tanpa ini, Actions gagal dengan:

```text
fatal: could not read Username for 'https://github.com': No such device or address
```

atau `ERROR: Repository not found` saat `git fetch`.

**Cara paling simple:** satu SSH key di **akun GitHub** (bukan 3 Deploy key
per repo). Akun itu harus punya akses ke infra + backend + web.

### 1. Buat key di VPS (sekali)

```sh
ssh-keygen -t ed25519 -C "vps-mylelang-deploy" -f ~/.ssh/mylelang_deploy -N ""
cat ~/.ssh/mylelang_deploy.pub
```

### 2. Jangan pakai Deploy key per-repo untuk jalur ini

Kalau key yang sama sempat ditambah di **Settings → Deploy keys** suatu repo,
**hapus dulu**. Satu public key tidak bisa sekaligus jadi Deploy key repo dan
SSH key akun.

### 3. Tambah key ke akun GitHub

1. Copy seluruh isi `~/.ssh/mylelang_deploy.pub` (satu baris, termasuk
   `ssh-ed25519 AAAA... vps-mylelang-deploy`).
2. GitHub → foto profil → **Settings → SSH and GPG keys → New SSH key**.
3. Title: `vps-mylelang-dev` · Key type: Authentication Key · paste → Save.
4. Pastikan akun ini owner/collaborator di ketiga repo.

### 4. SSH config di VPS

```sh
cat > ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/mylelang_deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

ssh -T git@github.com
```

Pertama kali akan muncul fingerprint host GitHub. Pastikan:

`SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`

lalu ketik `yes`.

Yang diharapkan:

```text
Hi <username>! You've successfully authenticated, but GitHub does not provide shell access.
```

Kalau yang muncul `Hi owner/nama-repo!`, key masih terpasang sebagai **Deploy
key** — ulangi langkah 2–3.

### 5. Pastikan nama repo GitHub benar

Buka di browser, contoh:

- `https://github.com/bagawe/mylelang-infra`
- `https://github.com/bagawe/mylelangbackend`
- `https://github.com/bagawe/mylelangweb`

`OWNER` di dokumentasi = username/org sungguhan (mis. `bagawe`), **bukan**
teks literal `OWNER`.

Kalau repo sempat typo (`mylelang-nfra`), rename di GitHub:
**Settings → General → Repository name** → `mylelang-infra`.

### 6. Set remote ketiga repo ke SSH

```sh
cd /opt/mylelang

# Sesuaikan bagawe jika owner berbeda
git -C mylelang-infra   remote set-url origin git@github.com:bagawe/mylelang-infra.git
git -C mylelangbackend  remote set-url origin git@github.com:bagawe/mylelangbackend.git
git -C mylelangweb      remote set-url origin git@github.com:bagawe/mylelangweb.git

git -C mylelang-infra   remote -v
git -C mylelangbackend  remote -v
git -C mylelangweb      remote -v
```

Harus `git@github.com:...` (bukan `https://`).

### 7. Tes fetch (wajib lolos ketiganya)

```sh
git -C /opt/mylelang/mylelang-infra fetch
git -C /opt/mylelang/mylelangbackend fetch
git -C /opt/mylelang/mylelangweb fetch
```

### 8. Tes deploy + Actions

```sh
cd /opt/mylelang/mylelang-infra
./scripts/deploy.sh
```

Lalu di GitHub: **Actions → deploy-dev → Run workflow**.

### Checklist

| # | Cek |
|---|---|
| 1 | Deploy key duplikat di repo sudah dihapus |
| 2 | Public key ada di **akun** → SSH and GPG keys |
| 3 | `ssh -T git@github.com` → `Hi <user>!` |
| 4 | Remote = `git@github.com:<user>/...` (bukan `OWNER`, bukan HTTPS) |
| 5 | Nama repo GitHub = `mylelang-infra` (bukan `mylelang-nfra`) |
| 6 | `git fetch` sukses di ketiga folder |
| 7 | Actions deploy hijau |

---

## Deploy harian

**Otomatis:** push `main` di backend atau web.

**Manual:**

```sh
cd /opt/mylelang/mylelang-infra && ./scripts/deploy.sh
```

Kalau hanya ubah `env/dev.env` (tanpa ubah `NEXT_PUBLIC_*`), cukup:

```sh
docker compose --env-file env/dev.env up -d
```

Kalau `NEXT_PUBLIC_*` berubah, **wajib rebuild** web (`./scripts/deploy.sh`).

---



## Troubleshooting singkat


| Gejala | Cek |
| --- | --- |
| `Unit file docker.service does not exist` | Docker belum terpasang. Jalankan bootstrap / install Docker CE resmi |
| `usermod: group 'docker' does not exist` | Install Docker dulu, lalu `getent group docker \|\| sudo groupadd docker` |
| `permission denied` docker.sock | User belum di group docker / belum re-login |
| `could not read Username for 'https://github.com'` | Remote masih HTTPS. Ikuti [VPS ↔ GitHub SSH](#vps--github-ssh-wajib-untuk-actions--deploysh) |
| `ERROR: Repository not found` (git fetch) | Remote salah: teks literal `OWNER`, typo `mylelang-nfra`, atau akun SSH tidak punya akses |
| `Hi owner/repo!` di `ssh -T` | Key masih Deploy key per-repo; pindahkan ke SSH key **akun** |
| Sertifikat Caddy gagal | DNS ke IP VPS? Proxy Cloudflare abu-abu? Port 80 terbuka? |
| Web 502 / `web:3003 connection refused` | Web listen port salah — pastikan compose override `PORT=3003` untuk service web |
| Browser hit `localhost:3003/api` | Rebuild web setelah fix `NEXT_PUBLIC_*` (di-bake saat build) |
| Upload stuck `QUARANTINED` | Tunggu ClamAV healthy |
| OOM saat build | Swap 4 GB: `free -h` |
| `TAILSCALE_IP is empty` di deploy | Isi `TAILSCALE_IP` di `env/dev.env` (`tailscale ip -4` atau `127.0.0.1`) |
| Laptop tidak connect DB/MinIO | Tailscale up di kedua sisi? `TAILSCALE_IP` sudah di-set + `compose up -d postgres minio`? |
| `ss` menunjukkan `0.0.0.0:5432` | `TAILSCALE_IP` kosong/salah — set IP lalu recreate postgres/minio |


---



## Security follow-ups

- Rotate service key `web-bff` yang pernah ter-expose di lokal (`mylelangweb/.env`).
- `env/dev.env` mode `600`; jangan commit.
- Backup 4 encryption key out-of-band.
- Postgres/MinIO hanya di Tailscale (atau localhost); jangan publish ke `0.0.0.0`.
- SSH publik tetap key-only untuk Actions; manusia lebih aman lewat Tailscale.
- Setelah HTTPS stabil, opsional: aktifkan Cloudflare proxy (oranye) + SSL mode **Full (strict)**.

