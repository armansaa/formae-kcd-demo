# formae agent `formae-kcd`

The formae agent for project `kcd-2026` on GKE `gke-research-lab` (`asia-southeast2-a`),
namespace `formae-kcd`. The workflows reach it at `http://formae.formae-kcd.svc.cluster.local:49684`.

```
setup/formae/
├── values.yaml              formae-helm chart values, rendered into manifests/formae.yaml
└── manifests/               kubectl apply -k
    ├── kustomization.yaml   namespace formae-kcd + Recreate strategy (SQLite on a RWO PVC)
    ├── namespace.yaml
    └── formae.yaml          `helm template` output (ServiceAccount, ConfigMap, Service, PVC, Deployment)
```

## Apply

The agent's basic auth lives in Secret `formae-auth` (username plus a bcrypt hash of the
password), created with kubectl and never committed:

```bash
kubectl create namespace formae-kcd
kubectl -n formae-kcd create secret generic formae-auth \
  --from-literal=username=formae --from-literal=password='<bcrypt hash>'

kubectl diff  -k setup/formae/manifests
kubectl apply -k setup/formae/manifests
kubectl -n formae-kcd rollout status deploy/formae
```

After changing `values.yaml` or the Secret, run `kubectl -n formae-kcd rollout restart deploy/formae`
(env and config are read at pod start).

## Change the agent configuration

Edit `values.yaml`, render `manifests/formae.yaml` again (the command is at the top of
`values.yaml`; chart formae-helm at commit `e602745`), then `kubectl diff -k` and `kubectl apply -k`.

## GCP prerequisites

The agent uses one identity for GCP **and** Kubernetes: GSA
`formae-agent@kcd-2026.iam.gserviceaccount.com` through Workload Identity (annotation
`iam.gke.io/gcp-service-account` on ServiceAccount `formae`). Kubernetes targets use `GKEAuth`, so
cluster access comes from IAM, without Kubernetes RBAC.

```bash
# KSA formae-kcd/formae may act as the GSA (Workload Identity)
gcloud iam service-accounts add-iam-policy-binding \
  formae-agent@kcd-2026.iam.gserviceaccount.com --project kcd-2026 \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:kcd-2026.svc.id.goog[formae-kcd/formae]"
```

Give the GSA the project roles your formae need (read for discovery, write for what they create).

The cluster endpoint and CA are not written in a forma: `GKEAuth` refers to the
`GCP::Container::Cluster` found by the agent's **discovery** through a `ClusterResolvable` (stack
`$unmanaged`, label = cluster name). Discovery runs every 30 minutes (`values.yaml` → `discovery`),
read-only, and scans projects that already have a GCP target on the agent (registered once a GCP
forma of the project is applied, e.g. the bucket). To run it now:
`curl -X POST -u formae:<password> http://formae.formae-kcd.svc.cluster.local:49684/api/v1/admin/discover`.

The default StorageClass (`standard-rwo`) backs the PVC `formae-data`.
