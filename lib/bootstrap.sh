# lib/bootstrap.sh
# Color support (disable with NO_COLOR=1 or when not a TTY)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_INFO="\033[1;34m"   # bright blue
  C_GOOD="\033[1;32m"   # bright green
  C_WARN="\033[1;33m"   # yellow
  C_ERR="\033[1;31m"    # red
  C_CMD="\033[1;36m"    # cyan
  C_RESET="\033[0m"
else
  C_INFO=""; C_GOOD=""; C_WARN=""; C_ERR=""; C_CMD=""; C_RESET="";
fi

log()  { printf "%b[INFO]%b %s\n"  "$C_INFO" "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n"  "$C_WARN" "$C_RESET" "$*"; }
err()  { printf "%b[ERROR]%b %s\n" "$C_ERR"  "$C_RESET" "$*" >&2; }

install_jq_if_missing() {
  if command -v jq >/dev/null 2>&1; then return 0; fi
  warn "jq not found. Installing (Debian/Ubuntu)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y jq
  else
    err "Automatic jq install only implemented for Debian/Ubuntu."
    exit 69
  fi
}

check_az_cli() {
  command -v az >/dev/null 2>&1 || { err "Azure CLI 'az' not found. Please install it first."; exit 69; }
}

check_ssh_keys() {
  local pub="$1" priv="$2"
  [ -f "$pub"  ] || { err "Public key not found: $pub"; exit 66; }
  [ -f "$priv" ] || { err "Private key not found: $priv"; exit 66; }
}

azure_login() {
  if az account show >/dev/null 2>&1; then
    log "Already logged into Azure CLI."
    return 0
  fi
  if [[ -n "${AZURE_CLIENT_ID-}" && -n "${AZURE_CLIENT_SECRET-}" && -n "${AZURE_TENANT_ID-}" ]]; then
    log "Logging in with service principal..."
    az login --service-principal \
      --username "$AZURE_CLIENT_ID" \
      --password "$AZURE_CLIENT_SECRET" \
      --tenant   "$AZURE_TENANT_ID" >/dev/null
  else
    warn "No SP env vars. Using device code login..."
    az login --use-device-code >/dev/null
  fi
  az account show >/dev/null 2>&1 || { err "Azure login failed"; exit 77; }
  log "Azure login successful."
}

bootstrap_all() {
  local pub="$1" priv="$2"
  install_jq_if_missing
  check_az_cli
  check_ssh_keys "$pub" "$priv"
  azure_login
}
