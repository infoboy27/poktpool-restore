#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
BASE_DIR="${BASE_DIR:-/root}"
WORKDIR="${WORKDIR:-$BASE_DIR/poktpool}"
GIT_BRANCH="${GIT_BRANCH:-main}"

REPO_BLOCKJOBPICKER="https://github.com/infoboy27/blockjobpicker.git"
REPO_POKTPOOLDB="https://github.com/infoboy27/poktpooldb.git"
REPO_POKTPOOLUI="https://github.com/infoboy27/poktpoolui.git"
REPO_POKTPOOL="https://github.com/infoboy27/poktpool.git"

# Git credentials (loaded from .env if available)
GIT_TOKEN="${GIT_TOKEN:-}"

# Storj configuration (loaded from .env if available)
STORJ_BUCKET="${STORJ_BUCKET:-blockchains}"
STORJ_PREFIX="${STORJ_PREFIX:-postgres}"
STORJ_ACCESS_GRANT="${STORJ_ACCESS_GRANT:-}"

# Storj dump paths (will be constructed after .env is loaded)
DUMP_POKTPOOLDB_REMOTE=""
DUMP_WAXTRAX_REMOTE=""

DUMP_POKTPOOLDB_LOCAL="20251217_142112_poktpooldb.dump"
DUMP_WAXTRAX_LOCAL="20251217_142112_waxtrax.dump"

# ====== HELPERS ======
log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }
die() { echo -e "\n\033[1;31m[x] $*\033[0m"; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run this as root (or with sudo)."
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

load_env_file() {
  local env_file="${1:-.env}"
  if [[ -f "$env_file" ]]; then
    log "Loading environment variables from $env_file..."
    # Export variables from .env file, ignoring comments and empty lines
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    log "Environment variables loaded."
  else
    warn ".env file not found at $env_file. Git operations may fail for private repos."
  fi
}

inject_git_credentials() {
  local url="$1"
  if [[ -n "$GIT_TOKEN" ]]; then
    # Inject token into GitHub URL: https://github.com/... -> https://token@github.com/...
    echo "$url" | sed "s|https://github.com/|https://${GIT_TOKEN}@github.com/|"
  else
    echo "$url"
  fi
}

install_prereqs() {
  log "Installing base dependencies (git, curl, jq, unzip, ca-certificates)..."
  apt-get update -y
  apt-get install -y git curl jq unzip ca-certificates gnupg lsb-release
}

install_docker_compose_v2() {
  if has_cmd docker && docker compose version >/dev/null 2>&1; then
    log "Docker + Compose v2 are already installed."
    return
  fi

  log "Installing Docker Engine + Docker Compose v2 (official Docker repo)..."
  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  docker version >/dev/null
  docker compose version >/dev/null
  log "Docker + Compose v2 installed OK."
}

install_uplink() {
  if has_cmd uplink; then
    log "uplink is already installed: $(uplink version 2>/dev/null || echo 'installed')"
    return
  fi

  log "Installing uplink (Storj) from GitHub Releases..."
  # Detect arch
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Architecture not supported for uplink in this script: $arch" ;;
  esac

  # Uplink is distributed from storj/storj repository, not storj/uplink
  # Use direct download URL pattern: https://github.com/storj/storj/releases/latest/download/uplink_linux_<arch>.zip
  local url tmpdir
  url="https://github.com/storj/storj/releases/latest/download/uplink_linux_${arch}.zip"
  
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"

  log "Downloading uplink: $url"
  if ! curl -fL "$url" -o uplink.zip; then
    cd /
    rm -rf "$tmpdir"
    die "Failed to download uplink from $url"
  fi

  # Unpack
  unzip -q uplink.zip

  # Find binary
  local bin
  bin="$(find . -type f -name uplink -perm -111 | head -n1)"
  [[ -n "$bin" ]] || die "Could not find 'uplink' binary inside the asset."

  install -m 0755 "$bin" /usr/local/bin/uplink
  cd /
  rm -rf "$tmpdir"

  log "uplink installed: $(uplink version 2>/dev/null || echo 'installed')"
}

clone_or_update_repo() {
  local url="$1"
  local name="$2"
  local dir="$WORKDIR/$name"
  
  # Inject credentials if available
  local auth_url
  auth_url="$(inject_git_credentials "$url")"

  if [[ -d "$dir/.git" ]]; then
    log "Updating repo $name..."
    # Update remote URL if credentials are available
    if [[ -n "$GIT_TOKEN" && "$auth_url" != "$url" ]]; then
      git -C "$dir" remote set-url origin "$auth_url" || true
    fi
    if ! git -C "$dir" fetch --all --prune; then
      warn "Failed to fetch $name. Continuing..."
    fi
    # Try to checkout the specified branch, fallback to current branch
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$GIT_BRANCH"; then
      git -C "$dir" checkout "$GIT_BRANCH" 2>/dev/null || git -C "$dir" checkout -b "$GIT_BRANCH" "origin/$GIT_BRANCH" 2>/dev/null || true
    fi
    git -C "$dir" pull --rebase || true
  else
    log "Cloning repo $name..."
    if ! git clone "$auth_url" "$dir"; then
      warn "Failed to clone $name from $url"
      if [[ -z "$GIT_TOKEN" ]]; then
        warn "This may be a private repository. Ensure you have:"
        warn "  1. GIT_TOKEN set in .env file, or"
        warn "  2. SSH keys configured, or"
        warn "  3. Git credentials configured, or"
        warn "  4. Access to the repository"
      else
        warn "Clone failed even with credentials. Check token permissions."
      fi
      warn "Skipping $name..."
      return 1
    fi
    # Try to checkout the specified branch if it exists, otherwise stay on default
    cd "$dir"
    if git show-ref --verify --quiet "refs/remotes/origin/$GIT_BRANCH" 2>/dev/null; then
      git checkout "$GIT_BRANCH" 2>/dev/null || git checkout -b "$GIT_BRANCH" "origin/$GIT_BRANCH" 2>/dev/null || true
    else
      local current_branch
      current_branch="$(git branch --show-current 2>/dev/null || echo 'unknown')"
      log "Branch '$GIT_BRANCH' not found in $name, staying on default branch: $current_branch"
    fi
    cd - >/dev/null
  fi
  return 0
}

uplink_sanity_check() {
  log "Validating uplink (Storj access)..."
  local test_path="sj://${STORJ_BUCKET}/${STORJ_PREFIX}"
  
  if [[ -n "$STORJ_ACCESS_GRANT" ]]; then
    log "Using Storj Access Grant from .env file"
  fi
  
  if ! uplink ls "$test_path" >/dev/null 2>&1; then
    warn "uplink does NOT have configured access to list $test_path"
    if [[ -z "$STORJ_ACCESS_GRANT" ]]; then
      warn "Solution: Set STORJ_ACCESS_GRANT in .env file, or run 'uplink setup'"
    else
      warn "The provided STORJ_ACCESS_GRANT may be invalid or expired."
    fi
    die "Cannot continue without uplink access."
  fi
  log "uplink OK - access validated for $test_path"
}

ensure_docker_network() {
  local network_name="$1"
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    log "Creating Docker network: $network_name"
    docker network create "$network_name" || die "Failed to create network $network_name"
  else
    log "Docker network '$network_name' already exists"
  fi
}

compose_up_if_exists() {
  local dir="$1"
  local label="$2"

  cd "$dir"
  if [[ -f docker-compose.yml || -f docker-compose.yaml || -f compose.yml || -f compose.yaml ]]; then
    log "Starting $label with docker compose..."
    docker compose up -d --build
  else
    warn "Could not find docker-compose.yml in $dir. Skipping docker compose up for $label."
  fi
}

wait_for_container() {
  local cid="$1"
  local max_attempts=30
  local attempt=0
  
  while [[ $attempt -lt $max_attempts ]]; do
    if docker inspect "$cid" >/dev/null 2>&1 && [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" == "true" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  
  return 1
}

get_compose_container_id() {
  # args: service_name, compose_dir
  local service="$1"
  local dir="$2"
  local cid
  
  # Wait a moment for containers to be registered
  sleep 2
  
  cid="$(cd "$dir" && docker compose ps -q "$service" 2>/dev/null | head -n1)"
  
  if [[ -z "$cid" ]]; then
    # Try alternative method: find by service name label
    cid="$(docker ps -q --filter "label=com.docker.compose.service=$service" --filter "label=com.docker.compose.project.working_dir=$dir" | head -n1)"
  fi
  
  echo "$cid"
}

get_container_env() {
  # args: container_id, env_var_name, default_value
  local cid="$1"
  local var_name="$2"
  local default="${3:-}"
  
  docker inspect "$cid" --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null \
    | grep "^${var_name}=" | cut -d= -f2- || echo "$default"
}

pg_restore_in_container_from_stdin() {
  # args: container_id, db_user, db_name, dump_file
  local cid="$1"
  local user="$2"
  local db="$3"
  local dump="$4"

  [[ -n "$cid" ]] || die "Empty container ID (service not started?)"
  [[ -f "$dump" ]] || die "Local dump does not exist: $dump"

  log "Restoring dump $(basename "$dump") to DB=$db USER=$user (container=$cid)..."
  
  # Wait for container to be ready
  if ! wait_for_container "$cid"; then
    die "Container $cid is not running after waiting."
  fi
  
  # Wait for PostgreSQL to be ready inside container
  local max_attempts=60
  local attempt=0
  while [[ $attempt -lt $max_attempts ]]; do
    if docker exec "$cid" pg_isready -U "$user" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  
  if [[ $attempt -eq $max_attempts ]]; then
    die "PostgreSQL is not ready in container $cid after waiting."
  fi
  
  # Restore dump
  if ! docker exec -i "$cid" pg_restore -U "$user" -d "$db" \
    --clean --if-exists --no-owner --no-acl -v \
    < "$dump"; then
    warn "pg_restore returned error code. Check the logs."
    warn "This may be normal if the DB already exists and has data."
  else
    log "Restore completed successfully."
  fi
}

ensure_db_exists() {
  # args: container_id, db_user, db_name
  local cid="$1"
  local user="$2"
  local db="$3"

  log "Checking existence of DB '$db'..."
  
  # Wait for PostgreSQL to be ready
  local max_attempts=60
  local attempt=0
  while [[ $attempt -lt $max_attempts ]]; do
    if docker exec "$cid" pg_isready -U "$user" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  
  if [[ $attempt -eq $max_attempts ]]; then
    die "PostgreSQL is not ready in container $cid."
  fi
  
  # Check if DB exists (try multiple methods for reliability)
  # Connect to 'postgres' database for the check, as the target DB might not exist yet
  local db_exists=false
  if docker exec "$cid" psql -U "$user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null | grep -q 1; then
    db_exists=true
  elif docker exec "$cid" psql -U "$user" -d postgres -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${db}"; then
    db_exists=true
  fi
  
  if [[ "$db_exists" == "true" ]]; then
    log "DB '$db' already exists."
  else
    log "Creating DB '$db'..."
    local create_output
    create_output="$(docker exec "$cid" createdb -U "$user" "$db" 2>&1)"
    local create_exit=$?
    
    if [[ $create_exit -eq 0 ]]; then
      log "DB '$db' created successfully."
    elif echo "$create_output" | grep -qi "already exists"; then
      log "DB '$db' already exists (detected during creation)."
    else
      warn "Error creating DB '$db': $create_output"
      die "Could not create DB '$db'."
    fi
  fi
}

main() {
  require_root
  
  # Load .env file from script directory or current directory
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$script_dir/.env" ]]; then
    load_env_file "$script_dir/.env"
  elif [[ -f ".env" ]]; then
    load_env_file ".env"
  fi
  
  # Export UPLINK_ACCESS if STORJ_ACCESS_GRANT is set (for uplink CLI)
  if [[ -n "$STORJ_ACCESS_GRANT" ]]; then
    export UPLINK_ACCESS="$STORJ_ACCESS_GRANT"
  fi
  
  # Construct Storj dump paths after loading .env
  DUMP_POKTPOOLDB_REMOTE="sj://${STORJ_BUCKET}/${STORJ_PREFIX}/poktpooldb/20251217_142112_poktpooldb.dump"
  DUMP_WAXTRAX_REMOTE="sj://${STORJ_BUCKET}/${STORJ_PREFIX}/waxtrax/20251217_142112_waxtrax.dump"
  
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  install_prereqs
  install_docker_compose_v2
  install_uplink

  log "Cloning repos..."
  if ! clone_or_update_repo "$REPO_BLOCKJOBPICKER" "blockjobpicker"; then
    warn "blockjobpicker clone failed - will skip this component"
  fi
  if ! clone_or_update_repo "$REPO_POKTPOOLDB" "poktpooldb"; then
    die "poktpooldb clone failed - this is required for the restore process"
  fi
  if ! clone_or_update_repo "$REPO_POKTPOOLUI" "poktpoolui"; then
    warn "poktpoolui clone failed - will skip this component"
  fi
  if ! clone_or_update_repo "$REPO_POKTPOOL" "poktpool"; then
    warn "poktpool clone failed - will skip this component"
  fi

  uplink_sanity_check

  # Ensure poktpool network exists (required by both poktpooldb and poktpool compose files)
  ensure_docker_network "poktpool"

  # ===== poktpooldb =====
  log "Entering poktpooldb and downloading dumps..."
  cd "$WORKDIR/poktpooldb"
  
  if [[ ! -f "$DUMP_POKTPOOLDB_LOCAL" ]]; then
    log "Downloading poktpooldb dump from Storj..."
    uplink cp "$DUMP_POKTPOOLDB_REMOTE" "./$DUMP_POKTPOOLDB_LOCAL"
  else
    log "poktpooldb dump already exists locally, skipping download."
  fi
  
  if [[ ! -f "$DUMP_WAXTRAX_LOCAL" ]]; then
    log "Downloading waxtrax dump from Storj..."
    uplink cp "$DUMP_WAXTRAX_REMOTE" "./$DUMP_WAXTRAX_LOCAL"
  else
    log "waxtrax dump already exists locally, skipping download."
  fi

  log "Starting poktpooldb (DBs) with docker compose..."
  docker compose up -d --build

  # Wait for containers to start
  log "Waiting for containers to be ready..."
  sleep 5

  # Detect containers by service names (as in your compose): poktpooldb and nodedb
  local poktpooldb_cid nodedb_cid
  poktpooldb_cid="$(get_compose_container_id "poktpooldb" "$WORKDIR/poktpooldb")"
  nodedb_cid="$(get_compose_container_id "nodedb" "$WORKDIR/poktpooldb")"

  [[ -n "$poktpooldb_cid" ]] || die "Could not detect container for service 'poktpooldb' (docker compose ps)."
  [[ -n "$nodedb_cid" ]] || die "Could not detect container for service 'nodedb' (docker compose ps)."

  log "Containers detected: poktpooldb=$poktpooldb_cid, nodedb=$nodedb_cid"

  # Get POSTGRES_USER/DB from each container (more reliable method)
  local pokt_user pokt_db node_user node_db
  pokt_user="$(get_container_env "$poktpooldb_cid" "POSTGRES_USER" "postgres")"
  pokt_db="$(get_container_env "$poktpooldb_cid" "POSTGRES_DB" "poktpooldb")"

  node_user="$(get_container_env "$nodedb_cid" "POSTGRES_USER" "postgres")"
  # In your case waxtrax exists; still, ensure it
  node_db="waxtrax"

  log "Configuration detected:"
  log "  poktpooldb: USER=$pokt_user, DB=$pokt_db"
  log "  nodedb: USER=$node_user, DB=$node_db"

  # Ensure DB exists before restore
  ensure_db_exists "$poktpooldb_cid" "$pokt_user" "$pokt_db"
  ensure_db_exists "$nodedb_cid" "$node_user" "$node_db"

  # Restore
  pg_restore_in_container_from_stdin "$poktpooldb_cid" "$pokt_user" "$pokt_db" "$WORKDIR/poktpooldb/$DUMP_POKTPOOLDB_LOCAL"
  pg_restore_in_container_from_stdin "$nodedb_cid" "$node_user" "$node_db" "$WORKDIR/poktpooldb/$DUMP_WAXTRAX_LOCAL"

  # ===== blockjobpicker =====
  if [[ -d "$WORKDIR/blockjobpicker" ]]; then
    log "Building and starting blockjobpicker..."
    cd "$WORKDIR/blockjobpicker"

    # Build image
    docker build -t blockjobpicker:latest .

    # Remove old container if exists
    docker rm -f blockjobpicker >/dev/null 2>&1 || true

    # Ensure network poktpool exists (created by poktpooldb compose)
    if ! docker network inspect poktpool >/dev/null 2>&1; then
      warn "Docker network 'poktpool' does not exist. Check poktpooldb compose (networks)."
      warn "Continuing without --network poktpool (but DB hostnames will not resolve)."
      docker run -d --name blockjobpicker --restart unless-stopped -p 5000:3000 blockjobpicker:latest
    else
      docker run -d --name blockjobpicker --restart unless-stopped --network poktpool -p 5000:3000 blockjobpicker:latest
    fi
  else
    warn "blockjobpicker directory not found. Skipping blockjobpicker setup."
  fi

  # ===== poktpool =====
  if [[ -d "$WORKDIR/poktpool" ]]; then
    compose_up_if_exists "$WORKDIR/poktpool" "poktpool"
  else
    warn "poktpool directory not found. Skipping poktpool setup."
  fi

  # ===== poktpoolui =====
  if [[ -d "$WORKDIR/poktpoolui" ]]; then
    compose_up_if_exists "$WORKDIR/poktpoolui" "poktpoolui"
  else
    warn "poktpoolui directory not found. Skipping poktpoolui setup."
  fi

  log "RESTORE COMPLETED. Check status:"
  echo "  - docker ps"
  echo "  - (poktpooldb) cd $WORKDIR/poktpooldb && docker compose ps"
  echo "  - logs: docker logs -f blockjobpicker"
}

main "$@"
