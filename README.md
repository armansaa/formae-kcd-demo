# formae-kcd-demo: reality-sync

Demo for the talk **"Beyond One-Way GitOps: Detecting and Reconciling Infrastructure Drift"**
(Kubernetes Cloud Native Days Indonesia 2026).

GitOps normally flows one way: Git → cluster. During an incident people still `kubectl edit`,
and Git silently falls behind. This repo uses [formae](https://formae.io) to run the other
direction too, **reality → Git**: out-of-band changes are detected, absorbed as desired state, and
a bot opens a PR so Git matches the cloud again.

One formae agent (namespace `formae-kcd` in GKE `gke-research-lab`, project `kcd-2026`), one flow,
one layout: every stack is a folder under `projects/kcd-2026/`.

## How it works

**Code → cloud (planned changes), Atlantis-style:**

```
PR that changes a forma ──▶ plan posted as a PR comment (formae plan: kcd-2026)
                            ├─ approve (someone other than the author)
                            ├─ comment `formae apply [-d <dir>]`   the agent makes it real
                            ├─ comment `formae plan [-d <dir>]`    must show no changes
                            └─ merge
```

`formae import [-d <dir>]` adopts a resource that already exists in the cloud instead of
creating it. Removing a forma folder in a PR and commenting `formae apply -d <dir>` destroys its
resources.

**Cloud → code (what really happened):**

```
 kubectl / console                formae agent (GKE)               GitHub
 ─────────────────                ──────────────────               ──────
 change a resource ─────────────▶ sync every 5 minutes
                                  "drift: limits.memory
                                   64Mi → 256Mi"
                                         │
                  reality-sync (every 10 minutes, ARC runner in GKE)
                                         │
                                  passes guardrails?
                                   ├─ yes → absorb, write the stack file back ─▶ PR "reality-sync: …"
                                   └─ no (delete/create, type outside the allowlist)
                                            changes nothing ──────────────────▶ Issue "BLOCKED"
```

Merging the bot's PR makes Git record reality. The plan on that PR should show no changes.

## Demo stacks

| Forma | What it is |
|---|---|
| `projects/kcd-2026/kube-manifest/promo` | Namespace `kcd-demo`: ConfigMap `promo-config` read by `promo-api`, and `promo-worker`, which is OOMKilled at a 64Mi memory limit |
| `projects/kcd-2026/kube-manifest/mario` | A small web app in namespace `mario`, with a Service and an HPA |
| `projects/kcd-2026/bucket/formae-demo` | A GCS bucket |
| `projects/kcd-2026/cloudsql/cloudsql-demo` | A Cloud SQL instance (one-way, see Known limitations) |

Example: the 02:14 hotfix. `promo-worker` crashes with exit code 137; someone raises the limit
directly in the cluster:

```bash
kubectl -n kcd-demo set resources deploy/promo-worker --limits=memory=256Mi
```

After the next sync and reality-sync run, the bot opens a PR whose Before/After table shows the
memory limit going from 64Mi to 256Mi.

## Guardrails

Nobody approves drift before it is absorbed, so these rules are the only brakes:

1. **Soft reconcile only.** Never `--force`, never `--mode patch`.
2. **Deletions and creations are never absorbed.** A missing resource can be a permissions or
   API problem, not a human decision. The run stops and opens an Issue.
3. **Type allowlist** (env `ALLOWED_TYPES` in `reality-sync.yml`). One blocked resource stops the
   run for that stack, because formae takes a single resolution for all drifted resources.
4. **reality-sync never applies code.** Code reaches the cloud only through an approved PR and a
   `formae apply` comment.
5. **No fork PRs on the self-hosted runner.** `formae apply` refuses PRs from forks, and
   *Require approval for all outside collaborators* must be on.
6. **No Kubernetes Secrets in a forma.** reality-sync writes live state into Git.

## Repo layout

| Path | Contents |
|---|---|
| `projects/kcd-2026/<kind>/<name>/main.pkl` | One stack per folder: stack, target and resources in one raw Pkl file (same shape as `formae extract`). Labels: stack `kcd-2026/<kind>/<name>`, target `kcd-2026/<cluster>` |
| `.github/workflows/taufik-formae-scan.yml` | Plan on every PR and push that touches a forma; hourly drift scan of every forma |
| `.github/workflows/taufik-formae-{comment-plan,apply,import}.yml` | `formae plan`, `formae apply`, `formae import` as PR comments |
| `.github/workflows/reality-sync.yml`, `.github/scripts/reality-sync.sh` | Detect drift → guardrails → absorb → write the stack back (`formae-extract-desired.sh`) → PR or Issue |
| `.github/scripts/formae-*.sh` | Plan, apply, import and report logic for the workflows |
| `.github/actions/formae-agent/` | CLI connection to the agent Service inside the cluster |
| `.github/workflows/build-runner-image.yml`, `runner/Dockerfile` | Runner image (actions-runner + formae + pkl + jq + gh), pushed to GHCR |
| `setup/formae/` | The formae agent: Helm values and rendered manifests (`kubectl apply -k`) |
| `setup/arc/runner-scale-set.yaml` | ARC values for the `formae-kcd` runner scale set |
| `setup/arc/reality-sync-trigger.yaml` | In-cluster CronJob that dispatches `reality-sync` every 10 minutes |

## Tested with formae 0.90.5 on GKE 1.35

- **Discovery** through `GKEAuth` + Workload Identity: existing cluster objects show up as
  `unmanaged`.
- **`extract --desired`** round-trips: applying its output gives "No changes needed".
- **Drift** from a `kubectl` change to a ConfigMap is reported as exactly the changed keys.
- **Revert** (code wins) restores the ConfigMap and patches only the declared fields.
- **Absorb** (reality wins) followed by extract gives a diff of exactly the changed keys.
- **Deployment drift** (memory limit raised with `kubectl set resources`) is absorbed. The extract
  also records fields the code left out (the default `strategy`, an empty `securityContext`, a
  `restartedAt` annotation from an earlier `rollout restart`), so the `promo` forma declares those
  defaults up front.
- **A key added to a ConfigMap** by someone else is not drift: formae owns only the keys the code
  declares.

## Run it yourself

You need a GKE cluster, a GCP service account for the agent (with the roles your formae need and
Workload Identity for the KSA `formae-kcd/formae`), and a GitHub App for the bot. Replace
`armansaa` in the files under `setup/arc/` with your GitHub account.

**1. GitHub App.** Settings → Developer settings → GitHub Apps → New GitHub App. Webhook off,
installable only on your account. Repository permissions, all **Read and write**: Contents, Pull
requests, Issues, Actions, Administration (ARC registers runners with it; the trigger CronJob
dispatches the workflow with Actions). Generate a private key, install the App on this repo only,
note the **App ID** and the **Installation ID**.

**2. Agent.** See [`setup/formae/README.md`](setup/formae/README.md).

**3. Repo settings.** Settings → Secrets and variables → Actions: variable `APP_ID`, secret
`APP_PRIVATE_KEY` (the `.pem`). Settings → Actions → General: fork pull request workflows
**Require approval for all outside collaborators**.

**4. Runner image.** The first push runs `build-runner-image`. Set the `formae-kcd-runner` package
visibility to **Public** so the cluster can pull it.

**5. Actions Runner Controller and the trigger.**

```bash
helm install arc -n arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

kubectl create namespace arc-runners
kubectl -n arc-runners create secret generic arc-github-app \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-file=github_app_private_key=<path/to/key.pem>
# basic auth of the agent, in plain text (the agent itself stores the bcrypt hash)
kubectl -n arc-runners create secret generic formae-kcd-agent-auth \
  --from-literal=username=formae --from-literal=password='<password>'

helm upgrade --install formae-kcd -n arc-runners -f setup/arc/runner-scale-set.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set --version 0.15.0
kubectl apply -f setup/arc/reality-sync-trigger.yaml
```

GitHub's own `schedule` is best effort (a `*/10` cron fired only a few times a day here), so the
CronJob dispatches `reality-sync` from inside the cluster.

**6. First stack.** Open a PR with a forma, comment `formae apply` after approval, then
`formae plan` (no changes), merge. Actions → **reality-sync** → Run workflow should report clean.

## Known limitations

- **Latency.** The agent syncs every 5 minutes and the trigger fires every 10 minutes, so a change
  can take up to 15 minutes to reach a PR. Use *Run workflow* to skip the second wait.
- **New resources are not adopted automatically.** A resource created outside the code is not
  drift; once discovery lists it as `managed:false`, a human decides whether to import it into a
  forma or delete it.
- **Container fields from code.** The k8s plugin (0.1.13) hides changes to
  `containers[].resources` from the diff. The `promo` and `mario` formae work around it with a
  subclass that redeclares the field.
- **Cloud SQL is one-way.** With GCP plugin 0.1.18 every `GCP::SQL::*` update is refused before
  any API call, so a revert to Cloud SQL is not possible; reality → Git still works.
- **Stack files are partly generated.** Manual edits through a PR are fine, but reality-sync
  rewrites the file after the next absorbed drift.
