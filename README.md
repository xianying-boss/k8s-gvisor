# Sandbox Cluster

A Kubernetes-native system for **VM-grade isolated code execution**, built on
[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
principles and [gVisor](https://gvisor.dev/) (`runsc`).

---

## Architecture

```
┌─────────────────────────── Control Plane (sandbox-system) ─────────────────┐
│                                                                              │
│   ┌──────────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│   │  sandbox-operator│───▶│ Redis Cache  │    │  SandboxJob CRD          │  │
│   │  (Go controller) │    │ pkg:sha256   │    │  spec.runtime: python    │  │
│   │                  │    │ TTL: 24h     │    │  spec.packages: [numpy]  │  │
│   │  1. Lifecycle    │    └──────────────┘    │  spec.code.inline: "..." │  │
│   │  2. Image select │                        └──────────────────────────┘  │
│   │  3. Cache lookup │                                                       │
│   │  4. Scheduling   │                                                       │
│   └────────┬─────────┘                                                       │
└────────────┼───────────────────────────────────────────────────────────────┘
             │ creates Pod (runtimeClass: gvisor)
             ▼
┌─────────────────────────── Execution Plane (sandbox-execution) ────────────┐
│                                                                              │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │  GKE Node (COS_CONTAINERD + sandbox_config gvisor)                   │  │
│   │                                                                       │  │
│   │   containerd ──▶ runsc shim ──▶ gVisor kernel (Go userspace)         │  │
│   │                                                                       │  │
│   │   ┌───────────────────────────────────────────┐                      │  │
│   │   │  execution pod                            │                      │  │
│   │   │  - init: write code to EmptyDir           │                      │  │
│   │   │  - executor: python:3.11-slim / node:20   │                      │  │
│   │   │  - NetworkPolicy: egress denied (default) │                      │  │
│   │   │  - UID 65534, no k8s API token            │                      │  │
│   │   └───────────────────────────────────────────┘                      │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Control Plane Responsibilities

| Responsibility         | Implementation                                           |
|------------------------|----------------------------------------------------------|
| Sandbox lifecycle      | `SandboxJobReconciler` state machine (Pending → … → Terminal) |
| Runtime image selection| `runtimeImages` map; substitutes cached image on hit    |
| Dependency cache       | Redis `HSET sandbox:pkgcache:<sha256>` with 24h TTL     |
| Workload scheduling    | nodeSelector + taint/toleration to execution-plane nodes|
| Network enforcement    | Per-job `NetworkPolicy` (deny-all egress by default)    |

### Execution Plane Responsibilities

| Responsibility         | Implementation                                           |
|------------------------|----------------------------------------------------------|
| VM-grade isolation     | gVisor `runsc` shim via `RuntimeClass: gvisor`          |
| Node segregation       | Taint `sandbox.k8s.io/execution:NoSchedule`             |
| Filesystem isolation   | EmptyDir workspace, read-only root where possible       |
| No k8s API access      | `automountServiceAccountToken: false`                   |

---

## Repository Layout

```
sandbox-cluster/
├── terraform/                  # Infrastructure provisioning
│   ├── main.tf                 # Root module (GKE + Helm)
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── gke/main.tf         # GKE cluster + two node pools (primary)
│       ├── eks/main.tf         # EKS stub (requires manual gVisor setup)
│       └── aks/main.tf         # AKS stub (requires manual gVisor setup)
├── manifests/                  # Raw Kubernetes YAML (apply order: 00→05)
│   ├── 00-namespaces.yaml
│   ├── 01-rbac.yaml
│   ├── 02-runtime-class.yaml
│   ├── 03-redis.yaml
│   ├── 04-network-policy.yaml
│   └── 05-crd-sandboxjob.yaml
├── helm/sandbox/               # Helm chart (wraps manifests + operator deploy)
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── control-plane/
│       ├── execution-plane/
│       └── redis/
└── operator/                   # Go operator source
    ├── main.go
    ├── go.mod
    ├── Dockerfile
    ├── Makefile
    ├── api/v1alpha1/
    │   ├── groupversion_info.go
    │   └── sandboxjob_types.go
    └── internal/controller/
        ├── sandboxjob_controller.go
        └── cache_manager.go
```

---

## Local Development (kind)

For local development and testing, use the scripts in `scripts/`. These replace Terraform entirely — no cloud account needed.

### Prerequisites (local)

| Tool | Min version | Install |
|------|-------------|---------|
| `kind` | 0.22 | https://kind.sigs.k8s.io/docs/user/quick-start/ |
| `kubectl` | 1.29 | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | 3.14 | https://helm.sh/docs/intro/install/ |
| `docker` | 24 | https://docs.docker.com/engine/install/ |
| `go` | 1.22 | https://go.dev/dl/ |

### Quick start

```bash
# 1. Spin up the full local cluster (cluster + gVisor + operator + Redis)
./scripts/local-up.sh

# 2. Run sample jobs (Python + Node.js + timeout test)
./scripts/test-job.sh

# 3. Run a specific test suite
./scripts/test-job.sh python      # Python job with numpy
./scripts/test-job.sh nodejs      # Node.js job with lodash
./scripts/test-job.sh cache       # Run twice — second should show cacheHit=true
./scripts/test-job.sh timeout     # Job that intentionally exceeds its timeout
./scripts/test-job.sh egress      # Job with allowNetworkEgress=true

# 4. Tear down
./scripts/local-down.sh           # removes kind cluster + Helm release
./scripts/local-down.sh --purge   # also removes Docker image + temp files
```

### local-up.sh flags

```bash
./scripts/local-up.sh --skip-build    # reuse existing sandbox-operator:local image
./scripts/local-up.sh --skip-gvisor   # skip runsc install (if nodes already configured)
```

### What local-up.sh does

```
1.  Preflight: verify kind, kubectl, helm, docker, go are installed
2.  kind create cluster (kind-config.yaml: 1 control + 2 execution workers)
3.  Install Calico CNI for NetworkPolicy enforcement
4.  Install gVisor (runsc) into each execution worker node container
5.  Patch containerd config.toml → register runsc runtime handler
6.  Taint execution nodes: sandbox.k8s.io/execution:NoSchedule
7.  kubectl apply manifests/00-05
8.  go vet + docker build sandbox-operator:local
9.  kind load docker-image (no registry needed)
10. helm install sandbox
11. Wait for deployments → print usage summary
```

### Architecture difference (local vs cloud)

| | Local (kind) | Cloud (GKE) |
|---|---|---|
| gVisor install | DaemonSet-style `docker exec` into kind nodes | Native: `sandbox_config { sandbox_type = "gvisor" }` |
| CNI | Calico (installed by script) | GKE Dataplane V2 / Calico |
| Node pools | kind workers with labels/taints | Separate GKE node pools |
| Image registry | `kind load docker-image` | GCR / Artifact Registry |
| Provisioning | `local-up.sh` | `terraform apply` |

---

## Cloud Deployment (Terraform)

### Prerequisites

- GCP project with GKE API enabled
- `gcloud`, `kubectl`, `terraform >= 1.7`, `helm >= 3.14`, `go >= 1.22`
- Container registry (GCR or Artifact Registry) for the operator image

---

## Deployment

### 1. Build and push the operator image

```bash
cd operator
make docker-build IMG=gcr.io/<PROJECT>/sandbox-operator:0.1.0
make docker-push  IMG=gcr.io/<PROJECT>/sandbox-operator:0.1.0
```

### 2. Provision infrastructure (GKE)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in project_id etc.
terraform init
terraform plan
terraform apply
```

After apply, update your kubeconfig:
```bash
gcloud container clusters get-credentials sandbox-cluster \
  --region us-central1 --project <PROJECT>
```

### 3. Install CRD and manifests

```bash
kubectl apply -f manifests/   # applies in lexicographic order (00→05)
```

### 4. Install Helm chart (if not using Terraform)

```bash
helm upgrade --install sandbox helm/sandbox \
  --namespace sandbox-system --create-namespace \
  --set operator.image.repository=gcr.io/<PROJECT>/sandbox-operator \
  --set operator.image.tag=0.1.0
```

---

## Usage

### Submit a Python sandbox job

```yaml
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: hello-python
  namespace: sandbox-system
spec:
  runtime: python
  packages:
    - numpy
    - pandas
  timeoutSeconds: 60
  code:
    inline: |
      import numpy as np
      import pandas as pd
      arr = np.array([1, 2, 3, 4, 5])
      print(f"Mean: {arr.mean()}, Std: {arr.std():.4f}")
      df = pd.DataFrame({"x": arr, "y": arr ** 2})
      print(df)
```

```bash
kubectl apply -f job.yaml
kubectl get sbj hello-python -w
# NAME           RUNTIME   PHASE       CACHEHIT   EXITCODE   AGE
# hello-python   python    Succeeded   false      0          45s
```

### Submit a Node.js sandbox job

```yaml
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: hello-node
  namespace: sandbox-system
spec:
  runtime: nodejs
  packages:
    - lodash
  timeoutSeconds: 30
  code:
    inline: |
      const _ = require('lodash');
      const nums = _.range(1, 6);
      console.log('Sum:', _.sum(nums));
      console.log('Chunk:', JSON.stringify(_.chunk(nums, 2)));
```

### Submit code from a ConfigMap

```bash
kubectl create configmap my-script \
  --from-file=code.py=./my_analysis.py \
  -n sandbox-system

kubectl apply -f - <<EOF
apiVersion: sandbox.k8s.io/v1alpha1
kind: SandboxJob
metadata:
  name: from-configmap
  namespace: sandbox-system
spec:
  runtime: python
  code:
    configMapRef:
      name: my-script
      key: code.py
EOF
```

### Enable network egress (e.g. to call an API)

```yaml
spec:
  allowNetworkEgress: true   # NetworkPolicy will allow all egress
```

---

## Security Model

| Layer              | Mechanism                                          |
|--------------------|----------------------------------------------------|
| Kernel isolation   | gVisor `runsc` — user-space kernel, not host kernel|
| Container escape   | No privileged containers, no host PID/network      |
| k8s API access     | `automountServiceAccountToken: false`              |
| Network egress     | Default-deny NetworkPolicy; opt-in per job         |
| Lateral movement   | Execution pods cannot reach `sandbox-system`       |
| Privilege          | UID 65534 (nobody), `runAsNonRoot: true`           |
| Seccomp            | `RuntimeDefault` profile on all pods               |

---

## EKS / AKS Notes

GKE is the easiest target because `sandbox_config { sandbox_type = "gvisor" }` on the
node pool handles gVisor installation automatically.

For **EKS/AKS**, set `executionPlane.installer.enabled: true` in `values.yaml`.
The Helm chart will deploy a privileged DaemonSet that:
1. Copies the `runsc` binary to the host
2. Patches `/etc/containerd/config.toml` to register the `runsc` runtime
3. Restarts `containerd`

See `terraform/modules/eks/main.tf` and `terraform/modules/aks/main.tf` for
node pool bootstrap guidance.
