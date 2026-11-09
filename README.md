# mylelang-infra

Deployment/orchestration for **My Lelang** on a single development VPS
(8 GB RAM / 8 vCPU). Images are **built on the VPS** (no container registry);
Caddy terminates TLS; Postgres, Redis, MinIO and ClamAV run self-hosted in the
same Compose stack.

**Dev domains (current):**

| Hostname | Service |
|---|---|
| `https://dev.mylelang.id` | Web (Next.js) |
| `https://api.dev.mylelang.id` | API + WebSocket |

---

## Stack

| Service | Role | Notes |
|---|---|---|
| `caddy` | Reverse proxy + auto HTTPS | `dev.*` → web, `api.dev.*` → api |
| `web` | Next.js 16 (standalone) | `NEXT_PUBLIC_*` baked at build time |
| `api` | NestJS API (`:3000`, prefix `/api/v1`) | `NODE_ENV=development` |
| `worker` | BullMQ consumer | email outbox, upload scan pipeline |
| `postgres` | PostgreSQL 16 | volume `pgdata`, daily `pg_dump` |
| `redis` | Redis 7 (AOF) | volume `redisdata` |
| `minio` | S3-compatible storage | volume `miniodata` |
| `clamav` | Virus scan for private uploads | ~2 GB RAM; cold start several minutes |
| `migrate` / `seed` / `minio-init` | one-shot tools (profile `tools`) | run on demand |

Worker uses `CLAMD_HOST=clamav` / `CLAMD_PORT=3310` (Compose DNS). ClamAV is
not published on the host. Keep ~4 GB swap — ClamAV + `docker compose build`
can spike memory on an 8 GB box.

---

## On-disk layout (VPS)

```
/opt/mylelang/
├── mylelang-infra/     # this repo (main)
├── mylelangbackend/    # backend (develop)
└── mylelangweb/        # web (develop)
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

| Type | Name | Content | Proxy |
|---|---|---|---|
| `A` | `dev` | `<IP_VPS>` | DNS only |
| `A` | `api.dev` | `<IP_VPS>` | DNS only |

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
- firewall (OpenSSH + 80 + 443)
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

Infra sudah di-clone di langkah C. Sekarang clone app (boleh beda akun GitHub).
VPS harus punya akses ke kedua repo (HTTPS + PAT, atau SSH deploy key).

```sh
cd /opt/mylelang
git clone <URL_REPO_BACKEND>   mylelangbackend
git clone <URL_REPO_WEB>       mylelangweb

git -C mylelangbackend checkout develop
git -C mylelangweb checkout develop
```

Ganti `<URL_REPO_*>` dengan URL GitHub asli.

Contoh akses SSH GitHub di VPS (opsional):

```sh
ssh-keygen -t ed25519 -C "vps-mylelang-dev" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
# tambahkan public key ini sebagai Deploy key (read-only) di tiap repo GitHub
```

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
NEXT_PUBLIC_API_BASE_URL=https://api.dev.mylelang.id/api/v1
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

| Secret | Isi |
|---|---|
| `DEV_SSH_HOST` | IP VPS |
| `DEV_SSH_USER` | user SSH (anggota group `docker`) |
| `DEV_SSH_KEY` | private key PEM user itu |
| `DEV_SSH_PORT` | `22` (atau port SSH custom) |

Workflow: push ke branch `develop` → SSH ke VPS → jalankan `scripts/deploy.sh`.

Pastikan public key pasangan `DEV_SSH_KEY` sudah ada di `~/.ssh/authorized_keys` di VPS.

---

## Deploy harian

**Otomatis:** push `develop` di backend atau web.

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
|---|---|
| `Unit file docker.service does not exist` | Docker belum terpasang. Jalankan **C1b** (repo resmi), baru `systemctl enable --now docker` |
| `usermod: group 'docker' does not exist` | Sama: install Docker dulu (C1b), lalu `getent group docker \|\| sudo groupadd docker` |
| `permission denied` docker.sock | User belum di group docker / belum re-login; `groups` harus memuat `docker` |
| `docker compose: command not found` | Install `docker-compose-plugin` lewat C1b |
| Sertifikat Caddy gagal | DNS sudah ke IP VPS? Proxy Cloudflare masih abu-abu? Port 80 terbuka? `logs caddy` |
| `dig` masih IP lama | Tunggu propagasi / purge cache lokal |
| Upload stuck `QUARANTINED` | `docker compose ps clamav` — tunggu healthy |
| Web tidak reach API | `API_KEY`, `CORS_ORIGINS`, `NEXT_PUBLIC_*` sudah benar & web di-rebuild? |
| OOM saat build | Pastikan swap 4 GB aktif: `free -h` |

---

## Security follow-ups

- Rotate service key `web-bff` yang pernah ter-expose di lokal (`mylelangweb/.env`).
- `env/dev.env` mode `600`; jangan commit.
- Backup 4 encryption key out-of-band.
- MinIO console tidak di-expose lewat Caddy; akses via SSH tunnel bila perlu.
- Setelah HTTPS stabil, opsional: aktifkan Cloudflare proxy (oranye) + SSL mode **Full (strict)**.
