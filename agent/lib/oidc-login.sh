#!/usr/bin/env bash
# cn-root-docker/agent/lib/oidc-login.sh — headless Outline login for the `agent`
# identity through Authentik's flow-executor API. Sourced by provision.sh.
#
# oidc_login <username> <password>   → prints Outline's accessToken (JWT) on stdout
#
# Dance (all via the SOCKS proxy, one curl cookie jar):
#   1. GET  $OUTLINE/auth/oidc                → 302 to Authentik /application/o/authorize/?...  (+ Outline `state` cookie)
#   2. GET  that authorize URL (unauthenticated) → 302 to the login flow with ?next=...
#   3. executor(default-authentication-flow, query=next=...) : identification → password → (MFA skipped) → login → redirect
#   4. GET  the authorize URL again (now authenticated) → 302 into the authorization flow (plan stored in session)
#   5. executor(default-provider-authorization-explicit-consent, query=<authorize query>) : consent(token) → redirect to Outline callback
#   6. GET  the Outline callback → Set-Cookie accessToken
# Any ak-stage-access-denied / unknown component aborts with the component name so the
# operator can fall back to the email magic-link path (see agent/README.md).

: "${PROXY:?PROXY unset}"; : "${OUTLINE:?OUTLINE unset}"; : "${AUTH:?AUTH unset}"
AUTHN_FLOW="${AUTHN_FLOW:-default-authentication-flow}"
AUTHZ_FLOW="${AUTHZ_FLOW:-default-provider-authorization-explicit-consent}"

_ol_urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
_ol_jar_cookie() { awk -v n="$2" '$6==n {v=$7} END {print v}' "$1"; }          # <jar> <name>
_ol_location() { grep -i '^location:' | tail -1 | sed 's/^[Ll]ocation:[[:space:]]*//; s/\r$//'; }
_ol_abs() { case "$1" in http*) printf '%s' "$1" ;; *) printf '%s%s' "$AUTH" "$1" ;; esac; }
_ol_query() { printf '%s' "${1#*\?}"; }                                          # everything after the first '?'

# executor <jar> <flow-slug> <query-string> <username> <password> → prints final redirect target
_ol_executor() {
  local jar="$1" slug="$2" q="$3" user="$4" pass="$5"
  local url; url="${AUTH}/api/v3/flows/executor/${slug}/?query=$(_ol_urlenc "$q")"
  local resp comp csrf i
  resp=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -H 'Accept: application/json' "$url")
  for i in $(seq 1 12); do
    comp=$(jq -r '.component // empty' <<<"$resp")
    case "$comp" in
      xak-flow-redirect) jq -r '.to' <<<"$resp"; return 0 ;;
      ak-stage-identification) body=$(jq -cn --arg u "$user" '{component:"ak-stage-identification",uid_field:$u}') ;;
      ak-stage-password)       body=$(jq -cn --arg p "$pass" '{component:"ak-stage-password",password:$p}') ;;
      ak-stage-consent)        body=$(jq -c '{component:"ak-stage-consent",token:.token}' <<<"$resp") ;;
      ak-stage-access-denied)  echo "executor: access denied — $(jq -r '.error_message // .flow_info.title // "?"' <<<"$resp")" >&2; return 1 ;;
      "") echo "executor: no component in response: $(head -c 300 <<<"$resp")" >&2; return 1 ;;
      *)  echo "executor: unsupported stage component '${comp}' (flow ${slug})" >&2; return 1 ;;
    esac
    if jq -e '.response_errors and (.response_errors|length>0)' <<<"$resp" >/dev/null; then
      echo "executor: stage ${comp} rejected input: $(jq -c '.response_errors' <<<"$resp")" >&2; return 1
    fi
    csrf=$(_ol_jar_cookie "$jar" authentik_csrf)
    resp=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" \
             -H 'Accept: application/json' -H 'Content-Type: application/json' \
             -H "X-authentik-CSRF: ${csrf}" -H "Referer: ${AUTH}/" -H "Origin: ${AUTH}" \
             -X POST --data "$body" "$url")
  done
  echo "executor: too many stages without completion (flow ${slug})" >&2; return 1
}

oidc_login() {
  local user="$1" pass="$2" jar hdr authz_url login_url next_q to authz2 flow_q callback token
  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  # 1. Outline starts the OIDC dance and pins its `state` cookie.
  hdr=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -c "$jar" -D - -o /dev/null "${OUTLINE}/auth/oidc")
  authz_url=$(_ol_location <<<"$hdr"); [[ "$authz_url" == *"/application/o/authorize/"* ]] || { echo "oidc: unexpected redirect from /auth/oidc: ${authz_url:-<none>}" >&2; return 1; }
  # 2. Unauthenticated → Authentik sends us to the login flow with ?next=
  hdr=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -D - -o /dev/null "$authz_url")
  login_url=$(_ol_location <<<"$hdr")
  if [[ -z "$login_url" ]]; then echo "oidc: authorize did not redirect (already authenticated?)" >&2; return 1; fi
  next_q=$(_ol_query "$login_url")                # e.g. next=%2Fapplication%2Fo%2Fauthorize%2F%3F...
  [[ "$next_q" == next=* ]] || next_q="next=$(_ol_urlenc "/application/o/authorize/?$(_ol_query "$authz_url")")"
  # 3. Authentication flow.
  to=$(_ol_executor "$jar" "$AUTHN_FLOW" "$next_q" "$user" "$pass") || return 1
  # 4. Authorize again, now with a session → Authentik plans the authorization flow.
  authz2=$(_ol_abs "$to")
  hdr=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -D - -o /dev/null "$authz2")
  callback=$(_ol_location <<<"$hdr")
  if [[ "$callback" != *"oidc.callback"* ]]; then
    # 5. Consent (or anything else the authorization flow wants).
    flow_q=$(_ol_query "$authz2")
    to=$(_ol_executor "$jar" "$AUTHZ_FLOW" "$flow_q" "$user" "$pass") || return 1
    callback=$(_ol_abs "$to")
  fi
  [[ "$callback" == "${OUTLINE}"* ]] || { echo "oidc: final redirect is not Outline's callback: ${callback}" >&2; return 1; }
  # 6. Outline exchanges the code and sets accessToken.
  curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -o /dev/null "$callback"
  token=$(_ol_jar_cookie "$jar" accessToken)
  [[ -n "$token" ]] || { echo "oidc: Outline did not set accessToken after the callback" >&2; return 1; }
  printf '%s\n' "$token"
}
