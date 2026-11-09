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

Ikuti berurutan. Bagian A–B bisa dikerjakan sebelum/bersamaan dengan VPS.

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

### C. VPS: package, Docker, swap, firewall

SSH ke VPS sebagai user yang punya sudo:

```sh
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin git ufw

# User deploy harus bisa docker tanpa sudo
sudo usermod -aG docker "$USER"
# logout/login ulang agar group docker aktif

# Swap ~4 GB
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Firewall
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

### D. Clone tiga repo

```sh
sudo mkdir -p /opt/mylelang
sudo chown "$USER" /opt/mylelang
cd /opt/mylelang

git clone <URL_REPO_INFRA>     mylelang-infra
git clone <URL_REPO_BACKEND>   mylelangbackend
git clone <URL_REPO_WEB>       mylelangweb

cd mylelang-infra && git checkout main
cd ../mylelangbackend && git checkout develop
cd ../mylelangweb && git checkout develop
```

Ganti `<URL_REPO_*>` dengan URL GitHub asli (HTTPS atau SSH).

### E. Buat `env/dev.env`

```sh
cd /opt/mylelang/mylelang-infra
cp env/dev.env.example env/dev.env
chmod 600 env/dev.env
```

Isi minimal yang wajib diganti:

```env
APP_DOMAIN=dev.mylelang.id
API_DOMAIN=api.dev.mylelang.id
CADDY_EMAIL=admin@mylelang.id

NEXT_PUBLIC_APP_URL=https://dev.mylelang.id
NEXT_PUBLIC_API_BASE_URL=https://api.dev.mylelang.id/api/v1
NEXT_PUBLIC_WS_URL=https://api.dev.mylelang.id
CORS_ORIGINS=https://dev.mylelang.id

POSTGRES_PASSWORD=<password-kuat>
# DATABASE_URL harus pakai password yang sama
DATABASE_URL=postgresql://mylelang:<password-kuat>@postgres:5432/mylelang?schema=public

OBJECT_STORAGE_SECRET_KEY=<password-kuat-minio>

# Generate 4x terpisah:
#   openssl rand -hex 32
ACTIVATION_TOKEN_ENCRYPTION_KEY=<64-hex>
MFA_ENCRYPTION_KEY=<64-hex>
IDENTITY_ENCRYPTION_KEY=<64-hex>
BANK_ACCOUNT_ENCRYPTION_KEY=<64-hex>
```

`API_KEY` boleh dibiarkan placeholder dulu; di-mint setelah stack pertama kali naik (langkah G).

Simpan 4 encryption key di tempat aman di luar VPS. Kalau hilang, data terenkripsi tidak bisa dibaca lagi.

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
