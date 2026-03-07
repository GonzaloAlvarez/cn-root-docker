#!/bin/bash
set -e

if [ ! -f .env ]; then
  > .env
  while IFS= read -r line; do
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || ! "$line" =~ = ]]; then
      echo "$line" >> .env
      continue
    fi
    varname="${line%%=*}"
    default="${line#*=}"
    if [[ -n "$default" ]]; then
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

envsubst '${ROOT_DOMAIN} ${VPS_PUBLIC_IP} ${VPS_TAILNET_IP}' \
  < headscale/config.yaml.tmpl > headscale/config.yaml

envsubst '${ROOT_DOMAIN}' \
  < tailnet/coredns/Corefile.tmpl > tailnet/coredns/Corefile

envsubst '${ROOT_DOMAIN} ${VPS_TAILNET_IP}' \
  < tailnet/coredns/db.lab.domain.tmpl > tailnet/coredns/db.lab.domain

envsubst '${LAB_DOMAIN}' \
  < tailnet/consul/vps-services.json.tmpl > tailnet/consul/vps-services.json
