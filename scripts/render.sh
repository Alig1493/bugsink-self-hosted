#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/dist"
OVERLAYS="$REPO_ROOT/k8s/overlays"

mkdir -p "$DIST"

# ── headers ──────────────────────────────────────────────────────────────────

read -r -d '' LOCAL_HEADER <<'EOF' || true
# ==============================================================
# Bugsink — local / Minikube deployment manifest
# Generated from: k8s/overlays/local/
#
# BEFORE APPLYING — replace all CHANGEME values:
#
#   CHANGEME_POSTGRES_PASSWORD        password for the local postgres instance
#   CHANGEME_SECRET_KEY_MIN_50_CHARS  50+ char random Django signing key
#   CHANGEME_ADMIN_PASSWORD           password for the Bugsink admin account
#
# Requires Minikube (or any local cluster) with kubectl pointed at it.
#
# Apply:
#   kubectl apply -f bugsink-local.yaml
# ==============================================================
EOF

read -r -d '' NGINX_HEADER <<'EOF' || true
# ==============================================================
# Bugsink — nginx + NodePort deployment manifest
# Generated from: k8s/overlays/production/
#
# BEFORE APPLYING — replace all CHANGEME values:
#
#   CHANGEME_POSTGRES_PASSWORD        strong random password for postgres
#   CHANGEME_SECRET_KEY_MIN_50_CHARS  50+ char random Django signing key
#   CHANGEME_ADMIN_PASSWORD           password for the Bugsink admin account
#
# Also update in this file:
#   BASE_URL in the bugsink-config ConfigMap  → your actual domain
#
# Apply:
#   kubectl apply -f bugsink-nginx.yaml
# ==============================================================
EOF

read -r -d '' TRAEFIK_HEADER <<'EOF' || true
# ==============================================================
# Bugsink — Traefik + StatefulSet Postgres deployment manifest
# Generated from: k8s/overlays/production-traefik/
#
# BEFORE APPLYING — replace all CHANGEME values:
#
#   CHANGEME_POSTGRES_PASSWORD        strong random password for postgres
#   CHANGEME_SECRET_KEY_MIN_50_CHARS  50+ char random Django signing key
#   CHANGEME_ADMIN_PASSWORD           password for the Bugsink admin account
#
# Also update in this file:
#   BASE_URL in the bugsink-config ConfigMap  → your actual domain
#   host in the Ingress resource              → your actual domain
#
# Apply:
#   kubectl apply -f bugsink-traefik.yaml
# ==============================================================
EOF

read -r -d '' CNPG_HEADER <<'EOF' || true
# ==============================================================
# Bugsink — Traefik + CloudNativePG (HA Postgres) deployment manifest
# Generated from: k8s/overlays/production-cnpg/
#
# BEFORE APPLYING — replace all CHANGEME values:
#
#   CHANGEME_POSTGRES_PASSWORD        strong random password for postgres
#   CHANGEME_SECRET_KEY_MIN_50_CHARS  50+ char random Django signing key
#   CHANGEME_ADMIN_PASSWORD           password for the Bugsink admin account
#   CHANGEME_ACCESS_KEY_ID            object store access key (backup)
#   CHANGEME_SECRET_ACCESS_KEY        object store secret key (backup)
#
# Also update in this file:
#   BASE_URL in the bugsink-config ConfigMap  → your actual domain
#   host in the Ingress resource              → your actual domain
#   destinationPath in the Cluster resource   → your bucket name/prefix
#   endpointURL in the Cluster resource       → your object store endpoint
#     (remove the endpointURL line entirely for AWS S3)
#
# Requires the CNPG operator installed first:
#   kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
#
# Apply:
#   kubectl apply -f bugsink-cnpg.yaml
# ==============================================================
EOF

# ── placeholder env content ───────────────────────────────────────────────────

COMMON_POSTGRES='POSTGRES_USER=bugsink
POSTGRES_PASSWORD=CHANGEME_POSTGRES_PASSWORD
POSTGRES_DB=bugsink'

COMMON_BUGSINK='SECRET_KEY=CHANGEME_SECRET_KEY_MIN_50_CHARS
CREATE_SUPERUSER=admin@yourdomain.com:CHANGEME_ADMIN_PASSWORD'

CNPG_POSTGRES='username=bugsink
password=CHANGEME_POSTGRES_PASSWORD
POSTGRES_USER=bugsink
POSTGRES_PASSWORD=CHANGEME_POSTGRES_PASSWORD
POSTGRES_DB=bugsink'

CNPG_OBJECT_STORE='ACCESS_KEY_ID=CHANGEME_ACCESS_KEY_ID
SECRET_ACCESS_KEY=CHANGEME_SECRET_ACCESS_KEY'

# ── render helper ─────────────────────────────────────────────────────────────
# Usage: render_overlay <overlay-dir> <output-file> <header>
#        followed by pairs: <secret-filename> <placeholder-content>

render_overlay() {
  local dir="$OVERLAYS/$1" output="$DIST/$2" header="$3"
  shift 3

  local -a files=() saved=()

  while (( $# >= 2 )); do
    local f="$dir/secrets/$1"
    files+=("$f")
    saved+=("$(cat "$f" 2>/dev/null || printf '')")
    mkdir -p "$dir/secrets"
    printf '%s\n' "$2" > "$f"
    shift 2
  done

  _restore() {
    local i
    for i in "${!files[@]}"; do
      printf '%s' "${saved[$i]}" > "${files[$i]}"
    done
  }
  trap _restore EXIT

  { printf '%s\n---\n' "$header"; kubectl kustomize "$dir/"; } > "$output"
  printf '  wrote %s\n' "$output"

  trap - EXIT
  _restore
}

# ── per-overlay render functions ──────────────────────────────────────────────

render_local() {
  render_overlay local bugsink-local.yaml "$LOCAL_HEADER" \
    postgres.env "$COMMON_POSTGRES" \
    bugsink.env  "$COMMON_BUGSINK"
}

render_nginx() {
  render_overlay production bugsink-nginx.yaml "$NGINX_HEADER" \
    postgres.env "$COMMON_POSTGRES" \
    bugsink.env  "$COMMON_BUGSINK"
}

render_traefik() {
  render_overlay production-traefik bugsink-traefik.yaml "$TRAEFIK_HEADER" \
    postgres.env "$COMMON_POSTGRES" \
    bugsink.env  "$COMMON_BUGSINK"
}

render_cnpg() {
  render_overlay production-cnpg bugsink-cnpg.yaml "$CNPG_HEADER" \
    postgres.env     "$CNPG_POSTGRES" \
    bugsink.env      "$COMMON_BUGSINK" \
    object-store.env "$CNPG_OBJECT_STORE"
  render_cnpg_restore
}

read -r -d '' CNPG_RESTORE_HEADER <<'EOF' || true
# ==============================================================
# Bugsink — CNPG restore template
# Apply ONLY when recovering data from backup (data loss, corruption).
# See README Option C → Restore for the full procedure.
#
# BEFORE APPLYING — update these values:
#
#   CHANGEME_BUCKET_NAME   your object store bucket name
#   CHANGEME_ENDPOINT_URL  your object store endpoint URL
#     (remove the endpointURL line entirely for AWS S3)
#
#   Also: set targetTime just before data loss, or delete the
#   recoveryTarget block to restore to the latest backup.
#
# Apply:
#   kubectl apply -f bugsink-cnpg-restore.yaml
#   kubectl get cluster -n bugsink -w
# ==============================================================
EOF

render_cnpg_restore() {
  local src="$OVERLAYS/production-cnpg/cluster-restore.yaml"
  local output="$DIST/bugsink-cnpg-restore.yaml"
  { printf '%s\n---\n' "$CNPG_RESTORE_HEADER"; cat "$src"; } > "$output"
  printf '  wrote %s\n' "$output"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-all}" in
  local)   render_local ;;
  nginx)   render_nginx ;;
  traefik) render_traefik ;;
  cnpg)    render_cnpg ;;
  all)
    render_local
    render_nginx
    render_traefik
    render_cnpg
    ;;
  *)
    echo "Usage: $0 [nginx|traefik|cnpg|all]" >&2
    exit 1
    ;;
esac
