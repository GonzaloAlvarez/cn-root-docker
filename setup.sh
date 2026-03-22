#!/bin/bash
set -e

MODE="${1:-production}"

set_env_var() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

if [ ! -f .env ]; then
  > .env
  while IFS= read -r line; do
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || ! "$line" =~ = ]]; then
      echo "$line" >> .env
      continue
    fi
    varname="${line%%=*}"
    default="${line#*=}"
    if [[ "$varname" == *SECRET* ]]; then
      read -rsp "${varname}: " value
      echo
      echo "${varname}=${value}" >> .env
    elif [[ -n "$default" ]]; then
      read -r -p "${varname} [${default}]: " value
      echo "${varname}=${value:-$default}" >> .env
    else
      read -r -p "${varname}: " value
      echo "${varname}=${value}" >> .env
    fi
  done < .env.example
  echo ""
fi

set -o allexport
source .env
set +o allexport

mkdir -p certs

if [ "$MODE" = "staging" ]; then
  echo "Configuring staging ACME..."
  curl -sf -o certs/letsencrypt-stg-root-x1.pem \
    https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem
  curl -sf -o certs/letsencrypt-stg-root-x2.pem \
    https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem
  set_env_var ACME_CASERVER "https://acme-staging-v02.api.letsencrypt.org/directory"
  set_env_var SSL_CERT_DIR "/etc/ssl/certs:/staging-certs"
  echo "Done. To apply:"
  echo "  docker compose down && docker volume rm cloudnet_traefik_public_acme cloudnet_traefik_lab_acme"
  echo "  docker compose up -d traefik-public headscale ts-infra consul traefik-lab coredns prometheus grafana"
else
  echo "Configuring production ACME..."
  rm -f certs/letsencrypt-stg-root-*.pem
  set_env_var ACME_CASERVER "https://acme-v02.api.letsencrypt.org/directory"
  set_env_var SSL_CERT_DIR "/etc/ssl/certs"
  echo "Done. To apply:"
  echo "  docker compose down && docker volume rm cloudnet_traefik_public_acme cloudnet_traefik_lab_acme"
  echo "  docker compose up -d traefik-public headscale ts-infra consul traefik-lab coredns prometheus grafana"
fi

GOOGLE_OIDC_ALLOWED_USERS_YAML=$(echo "$GOOGLE_OIDC_ALLOWED_USERS" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^/    - "/' | sed 's/$/"/')
export GOOGLE_OIDC_ALLOWED_USERS_YAML

envsubst '${ROOT_DOMAIN} ${VPS_PUBLIC_IP} ${VPS_TAILNET_IP} ${GOOGLE_OIDC_CLIENT_ID} ${GOOGLE_OIDC_CLIENT_SECRET} ${GOOGLE_OIDC_ALLOWED_USERS_YAML}' \
  < headscale/config.yaml.tmpl > headscale/config.yaml

envsubst '${ROOT_DOMAIN}' \
  < tailnet/coredns/Corefile.tmpl > tailnet/coredns/Corefile

envsubst '${ROOT_DOMAIN} ${VPS_TAILNET_IP}' \
  < tailnet/coredns/db.lab.domain.tmpl > tailnet/coredns/db.lab.domain

envsubst '${LAB_DOMAIN}' \
  < tailnet/consul/vps-services.json.tmpl > tailnet/consul/vps-services.json

mkdir -p tailnet/alertmanager
envsubst '${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USERNAME} ${SMTP_PASSWORD} ${ALERT_EMAIL}' \
  < tailnet/alertmanager/alertmanager.yml.tmpl > tailnet/alertmanager/alertmanager.yml
