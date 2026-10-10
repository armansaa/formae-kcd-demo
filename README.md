# formae-kcd-demo — reality-sync

Demo untuk talk **"Beyond One-Way GitOps: Detecting and Reconciling Infrastructure Drift"**
(Kubernetes Cloud Native Days Indonesia 2026).

GitOps biasa berjalan satu arah: Git → cluster. Saat insiden, orang tetap melakukan
`kubectl edit` atau klik di console, dan Git diam-diam tertinggal. Repo ini menunjukkan arah
sebaliknya dengan [formae](https://formae.io): **kenyataan → Git**. Perubahan dari luar
dideteksi, diserap sebagai *desired intent*, lalu bot membuka PR yang menyamakan Git dengan
kondisi cluster. Git berhenti jadi gerbang dan berubah jadi catatan kenyataan.

```
 kubectl / console                formae agent (GKE)               GitHub
 ─────────────────                ──────────────────               ──────
 ubah ConfigMap  ──────────────▶  sync tiap 10 menit
                                  "drift: PROMO_ENABLED
                                   false → true"
                                         │
                  reality-sync (tiap 10 menit, runner ARC di GKE)
                                         │
                                  lolos pagar?
                                   ├─ ya  → absorb (--resolution)
                                   │        extract --desired ─────▶  PR "reality-sync: …"
                                   │                                  check verify: Git = kenyataan
                                   └─ tidak (delete/create, tipe di luar allowlist)
                                            tidak mengubah apa pun ─▶  Issue "DIBLOKIR"
```

## Isi repo

| Path | Isi |
|---|---|
| `stacks/*.pkl` | Satu file per stack, **dihasilkan** oleh `formae extract --desired`. Bot menimpanya |
| `scripts/reality-sync.sh` | Deteksi drift → pagar → absorb → tulis balik. Bisa dijalankan manual |
| `scripts/write-ci-profile.sh` | Profile CLI `ci` yang bicara ke Service agent di dalam cluster |
| `.github/workflows/reality-sync.yml` | Jadwal tiap 10 menit + tombol manual. Buka PR atau Issue |
| `.github/workflows/verify.yml` | Check di PR: simulate stack; PR bot wajib "tidak ada perubahan" |
| `.github/workflows/build-runner-image.yml` | Image runner (actions-runner + formae + pkl + jq) ke GHCR |
| `runner/Dockerfile` | Definisi image runner |
| `setup/kcd-demo-namespace-rbac.yaml` | Namespace demo + izin tulis agent (disiapkan infra, bukan formae) |
| `setup/arc/runner-scale-set.yaml` | Values ARC untuk runner scale set `formae-kcd` |

## Pagar pengaman

Tidak ada approval manusia sebelum drift diserap, jadi pagar ini satu-satunya rem:

1. **Soft reconcile saja.** Tidak pernah `--force`, tidak pernah `--mode patch`.
2. **Penghapusan/pembuatan dari luar tidak pernah diserap otomatis.** Resource yang hilang
   bisa berarti masalah izin atau API, bukan keputusan manusia. Run berhenti dan membuka Issue.
3. **Allowlist tipe**: `K8S::Core::ConfigMap`, `K8S::Apps::Deployment`, `K8S::Batch::CronJob`
   (env `ALLOWED_TYPES`). Satu resource yang kena pagar menghentikan seluruh run; formae
   mewajibkan satu resolusi memutuskan semua resource yang drift.
4. **Bot tidak pernah menerapkan perubahan kode.** Kalau file di `main` berbeda dari agent
   tanpa drift (mis. PR bot ditutup), run hanya mencatat `code-differs`.
5. **Repo publik + runner self-hosted**: workflow PR tidak jalan untuk fork, dan setting repo
   wajib *Require approval for all outside collaborators*.
6. **Tanpa Secret Kubernetes** di stack demo. reality-sync menulis kondisi live ke Git.

## Yang sudah diuji (formae 0.90.5, GKE 1.35)

| Uji | Hasil |
|---|---|
| Discovery objek cluster lewat `GKEAuth` + Workload Identity | Objek di namespace sistem GKE terlihat sebagai `unmanaged` |
| Deploy stack `kcd-demo-app` (ConfigMap + Deployment) | Berhasil, izin tulis hanya di `kcd-demo` |
| `extract --desired` (E2) | Berhasil, dan hasilnya round-trip: di-apply balik = "No changes needed" |
| G1: ConfigMap diubah via `kubectl` | Drift bersih: hanya dua key yang berubah |
| Revert (kode menang) | ConfigMap kembali; hanya field yang dideklarasikan yang di-patch |
| `rollout restart` (E3) | Annotation `restartedAt` tidak masuk desired state |

Cloud SQL sengaja **tidak** dimasukkan ke loop ini: di plugin GCP 0.1.18,
`GCP::SQL::DatabaseInstance` tidak mendukung update, dan extract setelah absorb gagal karena
field di luar skema. Detail di talk.

## Setup (sekali)

Prasyarat: cluster `gke-research-lab` dengan agent formae 0.90.5 (Helm, Service
`formae.formae.svc:49684`, basic auth), dan laptop yang sudah bisa
`formae agent status --profile gke-kcd`.

### 1. GitHub App untuk bot

Settings → Developer settings → GitHub Apps → **New GitHub App**:

- Nama: mis. `formae-reality-sync-armansaa` (harus unik di GitHub)
- Homepage URL: URL repo ini
- Webhook: **matikan** (Active tidak dicentang)
- Repository permissions:
  - Contents: **Read and write**
  - Pull requests: **Read and write**
  - Issues: **Read and write**
  - Administration: **Read and write** (dipakai ARC untuk mendaftarkan runner)
  - Metadata: Read (otomatis)
- Where can this app be installed: **Only on this account**

Setelah dibuat: catat **App ID**, klik *Generate a private key* (unduh `.pem`), lalu
*Install App* → hanya repo `formae-kcd-demo`. **Installation ID** ada di URL halaman instalasi
(`.../settings/installations/<ID>`).

### 2. Isi stack awal, buat repo, push

```bash
cd ~/Documents/formae-kcd-demo
formae extract --desired --yes --profile gke-kcd \
  --query 'stack:kcd-demo-app' stacks/kcd-demo-app.pkl
git init -b main && git add -A && git commit -m "formae-kcd-demo: reality-sync awal"
gh repo create armansaa/formae-kcd-demo --public --source . --push
```

Push pertama ini juga menjalankan `build-runner-image`. Setelah selesai, buka
Profile → Packages → `formae-kcd-runner` → Package settings → ubah visibilitas jadi
**Public** supaya GKE bisa menarik image tanpa kredensial.

### 3. Variable, secret, dan setting repo

Settings → Secrets and variables → Actions:

| Jenis | Nama | Isi |
|---|---|---|
| Variable | `APP_ID` | App ID dari langkah 1 |
| Secret | `APP_PRIVATE_KEY` | Seluruh isi file `.pem` |
| Secret | `FORMAE_USER` | Username basic auth agent (mis. `kcd`) |
| Secret | `FORMAE_PASSWORD` | Password asli (bukan hash bcrypt) |

Settings → Actions → General → *Fork pull request workflows from outside collaborators* →
**Require approval for all outside collaborators**.

### 4. Namespace demo (kalau belum)

```bash
kubectl apply -f setup/kcd-demo-namespace-rbac.yaml
```

### 5. Actions Runner Controller di GKE

```bash
helm install arc -n arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

kubectl create namespace arc-runners
kubectl -n arc-runners create secret generic arc-github-app \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=<path/ke/key.pem>

helm install formae-kcd -n arc-runners -f setup/arc/runner-scale-set.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

kubectl -n arc-systems get pods     # controller + listener formae-kcd harus Running
```

Runner `formae-kcd` akan muncul di Settings → Actions → Runners.

### 6. Run pertama

Actions → **reality-sync** → Run workflow. Hasil yang diharapkan: ringkasan
"bersih, tidak ada drift".

## Skenario demo G1: promo dinyalakan tanpa PR

```bash
kubectl -n kcd-demo patch configmap promo-config \
  --type merge -p '{"data":{"PROMO_ENABLED":"true","DISCOUNT_PCT":"25"}}'
kubectl -n kcd-demo rollout restart deploy/promo-api
```

Tunggu sync agent (≤10 menit), lalu Run workflow **reality-sync** (atau tunggu jadwal).
Hasil: PR `reality-sync: drift diserap di kcd-demo-app` berisi diff dua key di
`stacks/kcd-demo-app.pkl`, dengan check `verify` hijau.

- **Merge** → Git sama dengan kenyataan.
- **Tutup** → terapkan isi `main` manual dari laptop
  (`formae apply --mode reconcile --profile gke-kcd stacks/kcd-demo-app.pkl`); karena drift
  sudah diserap, itu tampil sebagai perubahan kode biasa (kode menang).

## Batasan yang diketahui

- Jadwal GitHub minimal 5 menit dan bisa telat; ditambah sync agent 10 menit. Untuk panggung,
  picu perubahan beberapa menit sebelum segmen dan pakai *Run workflow*.
- Resource baru (Wajah 2, mis. CronJob dibuat via `kubectl`) belum masuk loop. Itu langkah
  berikutnya: discovery → allowlist → adopt → PR.
- File di `stacks/` adalah kode hasil generate; edit manual tetap boleh lewat PR, tapi bot akan
  menimpanya dengan hasil `extract --desired` setelah drift berikutnya.
