# Bugsink Hosted

Self-hosted error tracking using [Bugsink](https://www.bugsink.com), deployed on Kubernetes with PostgreSQL persistence, horizontal autoscaling, and two production deployment options: nginx (NodePort) or Traefik (Ingress + automatic TLS).

## Architecture

**Option A — nginx (NodePort)**
```mermaid
flowchart TD
    A[Django App / Any App] -->|DSN over HTTPS| B[nginx\nTLS termination\nbugsink.yourdomain.com]
    B -->|localhost:30080| C[K8s NodePort Service]
    C --> D[Bugsink Deployment\n1-5 replicas]
    D --> E[(PostgreSQL\nStatefulSet)]
    E --> F[(PersistentVolumeClaim\n10Gi)]
    G[HPA] -->|watches CPU| D
```

**Option B — Traefik (Ingress)**
```mermaid
flowchart TD
    A[Django App / Any App] -->|DSN over HTTPS| B[Traefik\nIngress Controller\nport 443]
    B -->|cluster DNS| C[K8s ClusterIP Service]
    C --> D[Bugsink Deployment\n1-5 replicas]
    D --> E[(PostgreSQL\nStatefulSet)]
    E --> F[(PersistentVolumeClaim\n10Gi)]
    G[HPA] -->|watches CPU| D
    B -->|ACME| H[Let's Encrypt\nauto cert issuance]
    H -->|stores cert| I[K8s Secret\nbugsink-tls]
```

## What This Does

- Runs Bugsink (`bugsink/bugsink:2`) inside Kubernetes with a dedicated PostgreSQL instance
- PostgreSQL data is persisted via a `PersistentVolumeClaim` — survives pod restarts and rescheduling
- Bugsink scales horizontally (1–5 replicas) via a `HorizontalPodAutoscaler` based on CPU usage
- Postgres stays at a single replica — it is not horizontally scaled
- Two production options: nginx on the host (NodePort) or Traefik in-cluster (Ingress + automatic Let's Encrypt)
- Kustomize overlays separate local and production configuration cleanly — `production` for nginx, `production-traefik` for Traefik

## File Structure

```
Makefile
k8s/
├── base/                          # shared across all environments
│   ├── kustomization.yaml
│   ├── 00-namespace.yaml
│   ├── 01-postgres-statefulset.yaml
│   ├── 02-postgres-service.yaml
│   ├── 03-bugsink-configmap.yaml
│   ├── 04-bugsink-deployment.yaml
│   ├── 05-bugsink-service.yaml
│   └── 06-bugsink-hpa.yaml
└── overlays/
    ├── local/                     # minikube / local testing
    │   ├── kustomization.yaml
    │   ├── configmap-patch.yaml
    │   └── secrets/               # git-ignored, local credentials
    │       ├── postgres.env
    │       └── bugsink.env
    ├── production/                # nginx + NodePort (existing server with nginx)
    │   ├── kustomization.yaml
    │   ├── configmap-patch.yaml
    │   └── secrets/               # git-ignored, production credentials
    │       ├── postgres.env
    │       └── bugsink.env
    └── production-traefik/        # Traefik + ClusterIP + Ingress (Traefik as ingress controller)
        ├── kustomization.yaml
        ├── configmap-patch.yaml
        ├── service-patch.yaml     # patches NodePort → ClusterIP
        ├── ingress.yaml           # Traefik Ingress with ACME cert resolver
        └── secrets/               # git-ignored, production credentials
            ├── postgres.env
            └── bugsink.env
```

## Local Testing with Minikube

### Prerequisites

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- kubectl
- make

### Setup

```bash
# Start minikube
minikube start --memory=2048 --cpus=2

# Enable metrics-server (required for HPA)
minikube addons enable metrics-server
```

### Configure local overlay

Edit `k8s/overlays/local/configmap-patch.yaml`:

```yaml
BEHIND_HTTPS_PROXY: "False"
BASE_URL: "http://<minikube-ip>:30080"   # get IP with: minikube ip
```

Create `k8s/overlays/local/secrets/postgres.env`:
```
POSTGRES_USER=bugsink
POSTGRES_PASSWORD=localpassword
POSTGRES_DB=bugsink
```

Create `k8s/overlays/local/secrets/bugsink.env`:
```
SECRET_KEY=any-local-dev-key
CREATE_SUPERUSER=admin@example.com:admin
```

### Deploy

```bash
make deploy-local
make watch          # wait for pods to be Running
make minikube-url   # get the URL to open in browser
```

### Making Local Bugsink Reachable from Docker Containers

By default, Docker containers cannot reach the minikube IP (`192.168.49.2`) because they run on an isolated bridge network. To send error events from a Dockerised app to local Bugsink:

**Option A — host-gateway (recommended)**

Add to your app's `docker-compose.yml`:
```yaml
services:
  your-app:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Set your DSN to use `host.docker.internal`:
```
BUGSINK_DSN=http://<key>@host.docker.internal:30080/1
```

**Option B — ngrok tunnel**

```bash
ngrok http <minikube-ip>:30080
```

Use the ngrok `https://` URL as your DSN host. Also update `BASE_URL` in the local overlay to the ngrok URL and set `BEHIND_HTTPS_PROXY: "True"` since ngrok acts as an HTTPS proxy.

> Note: ngrok free tier URLs change on every restart.

## Production Deployment

### Option A — nginx (NodePort)

Use this when nginx is already running on the server and handling other sites.

**Checklist:**
- [ ] Domain DNS A record points to your server IP
- [ ] Certbot has issued certificates: `/etc/letsencrypt/live/bugsink.yourdomain.com/`
- [ ] `k8s/overlays/production/configmap-patch.yaml` has correct `BASE_URL`
- [ ] `k8s/overlays/production/secrets/` populated with strong credentials
- [ ] `overlays/*/secrets/` is in `.gitignore`
- [ ] metrics-server is installed on the cluster

**nginx server block:**

```nginx
server {
    listen 443 ssl;
    server_name bugsink.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/bugsink.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bugsink.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://localhost:30080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

**Deploy:**
```bash
make deploy-prod
make watch
make pvc
make hpa
```

---

### Option B — Traefik (Ingress)

Use this when Traefik is running as the cluster ingress controller. Traefik handles TLS automatically via Let's Encrypt — no Certbot needed.

**Checklist:**
- [ ] Domain DNS A record points to your server IP
- [ ] Traefik is deployed with a `certificatesResolvers.letsencrypt` block in its static config
- [ ] Port 80 is open on the server (Let's Encrypt HTTP challenge)
- [ ] `k8s/overlays/production-traefik/ingress.yaml` has correct domain
- [ ] `k8s/overlays/production-traefik/configmap-patch.yaml` has correct `BASE_URL`
- [ ] `k8s/overlays/production-traefik/secrets/` populated with strong credentials
- [ ] `overlays/*/secrets/` is in `.gitignore`
- [ ] metrics-server is installed on the cluster

**How Traefik issues the cert automatically:**

```
kubectl apply -k k8s/overlays/production-traefik/
  → Traefik sees the Ingress resource
  → contacts Let's Encrypt ACME API
  → Let's Encrypt validates via HTTP challenge on port 80
  → cert issued and stored as K8s Secret "bugsink-tls"
  → HTTPS starts working
```

Verify the cert was issued:
```bash
kubectl get secret bugsink-tls -n bugsink
```

**Deploy:**
```bash
kubectl apply -k k8s/overlays/production-traefik/
make watch
make pvc
make hpa
```

## Makefile Reference

| Command | Description |
|---|---|
| `make deploy-local` | Deploy to local cluster + restart bugsink |
| `make deploy-prod` | Deploy to production (nginx + NodePort) |
| `make deploy-prod-traefik` | Deploy to production (Traefik + Ingress) |
| `make diff-local` | Preview local changes before applying |
| `make diff-prod` | Preview production nginx changes before applying |
| `make diff-prod-traefik` | Preview production Traefik changes before applying |
| `make status` | Show all resources in namespace |
| `make watch` | Watch pods update in real time |
| `make logs` | Snapshot bugsink logs |
| `make logs-follow` | Live tail bugsink logs |
| `make logs-all` | Live tail including init container |
| `make logs-pod POD=<name>` | Logs for a specific pod |
| `make logs-postgres` | Live tail postgres logs |
| `make pvc` | Check postgres volume is Bound |
| `make hpa` | Check autoscaler status |
| `make minikube-url` | Print local service URL |
| `make teardown` | Delete everything including PVCs |
| `make teardown-pvc` | Delete only the postgres volume |

## Debugging CSRF Issues

CSRF errors are the most common issue when setting up a reverse proxy in front of Bugsink. Bugsink ships with a verbose CSRF middleware that shows detailed error messages including the exact headers Django received — use that output to diagnose misconfigured proxy headers.

For nginx, ensure these three headers are forwarded:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Real-IP $remote_addr;
```

And set `BEHIND_HTTPS_PROXY: "True"` in your overlay's `configmap-patch.yaml` so Django trusts those headers.

> Note: You never need to set `CSRF_TRUSTED_ORIGINS` with Bugsink — it is not required and should be left unset.

### Advanced CSRF debugging tool

If the verbose error message isn't enough, Bugsink has a built-in CSRF debugging tool. It is disabled by default for security reasons.

To enable it, add `DEBUG_CSRF` to your overlay's `configmap-patch.yaml`:

```yaml
data:
  BEHIND_HTTPS_PROXY: "True"
  BASE_URL: "https://bugsink.yourdomain.com"
  DEBUG_CSRF: "True"
```

Redeploy, then visit `https://bugsink.yourdomain.com/debug/csrf/` and press the button to get a full report of what headers and checks Django is seeing.

Disable it again once you're done — remove `DEBUG_CSRF` from the configmap and redeploy.

**For local testing with ngrok**, enable it in the local overlay:

```yaml
data:
  BEHIND_HTTPS_PROXY: "True"
  BASE_URL: "https://<your-ngrok-url>"
  DEBUG_CSRF: "True"
```

---

## Integrating with Your App

Bugsink is compatible with the Sentry SDK. Get your DSN from the Bugsink UI after creating a project.

```python
import sentry_sdk

sentry_sdk.init(
    dsn=BUGSINK_DSN,          # read from env var
    # DjangoIntegration is auto-enabled when Django is detected.
    # Add it explicitly only if you need to customise its options:
    # from sentry_sdk.integrations.django import DjangoIntegration
    # integrations=[DjangoIntegration()],
    send_default_pii=True,
    traces_sample_rate=0,     # Bugsink doesn't support tracing
    send_client_reports=False,
    auto_session_tracking=False,
)
```
