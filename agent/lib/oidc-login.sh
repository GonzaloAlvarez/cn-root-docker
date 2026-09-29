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
# Authentik headless pattern: GET the executor for a challenge, POST the stage
# response (which 302s back to the executor), then GET the executor again for the
# next challenge. Non-interactive stages (the skipped MFA validation, user login)
# run server-side between GETs. Some deployments set no authentik_csrf cookie for
# the anonymous flow; the header is sent only when the cookie exists.
_ol_executor() {
  local jar="$1" slug="$2" q="$3" user="$4" pass="$5"
  local url; url="${AUTH}/api/v3/flows/executor/${slug}/?query=$(_ol_urlenc "$q")"
  local resp comp body csrf post i
  get_challenge() { curl -sS -L --max-redirs 15 --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -H 'Accept: application/json' "$url"; }
  resp=$(get_challenge)
  for i in $(seq 1 12); do
    comp=$(jq -r '.component // empty' <<<"$resp")
    case "$comp" in
      xak-flow-redirect) jq -r '.to' <<<"$resp"; return 0 ;;
      ak-stage-identification) body=$(jq -cn --arg u "$user" '{component:"ak-stage-identification",uid_field:$u}') ;;
      ak-stage-password)       body=$(jq -cn --arg p "$pass" '{component:"ak-stage-password",password:$p}') ;;
      ak-stage-consent)        body=$(jq -c '{component:"ak-stage-consent",token:.token}' <<<"$resp") ;;
      ak-stage-access-denied)  echo "executor: access denied — $(jq -r '.error_message // .flow_info.title // "?"' <<<"$resp")" >&2; return 1 ;;
      "") echo "executor: no component in challenge: $(head -c 300 <<<"$resp")" >&2; return 1 ;;
      *)  echo "executor: unsupported stage component '${comp}' (flow ${slug})" >&2; return 1 ;;
    esac
    csrf=$(_ol_jar_cookie "$jar" authentik_csrf)
    # POST the stage (no -L): a validation failure comes back as 200 JSON with
    # response_errors; success comes back as a 302 whose body we ignore.
    post=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" \
             -H 'Accept: application/json' -H 'Content-Type: application/json' \
             ${csrf:+-H "X-authentik-CSRF: ${csrf}"} -H "Referer: ${AUTH}/" -H "Origin: ${AUTH}" \
             -X POST --data "$body" "$url")
    if [[ -n "$post" ]] && jq -e '(.response_errors // {}) | length > 0' <<<"$post" >/dev/null 2>&1; then
      echo "executor: stage ${comp} rejected input: $(jq -c '.response_errors' <<<"$post")" >&2; return 1
    fi
    resp=$(get_challenge)
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
  # 3. Authentication flow → completes with a redirect back to the OAuth authorize URL.
  to=$(_ol_executor "$jar" "$AUTHN_FLOW" "$next_q" "$user" "$pass") || return 1
  # 4. Follow the authorization side to Outline's callback, driving any flow we land
  #    on (consent, and anything else) through its executor. Bounded hop count.
  # Match ONLY a URL that begins with Outline's callback path. A plain
  # *oidc.callback* glob is wrong: the consent page's own redirect_uri= query
  # param contains the (url-encoded) callback string.
  local cb="${OUTLINE}/auth/oidc.callback"
  local url loc loc_abs slug q hop
  url=$(_ol_abs "$to"); callback=""
  for hop in 1 2 3 4 5 6 7 8; do
    case "$url" in "${cb}"*) callback="$url"; break ;; esac
    hdr=$(curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -D - -o /dev/null "$url")
    loc=$(_ol_location <<<"$hdr")
    if [[ -z "$loc" ]]; then echo "oidc: no redirect from ${url%%\?*} (hop ${hop})" >&2; return 1; fi
    loc_abs=$(_ol_abs "$loc")
    case "$loc_abs" in
      "${cb}"*) callback="$loc_abs"; break ;;
      *"/if/flow/"*|*"/api/v3/flows/executor/"*)
        slug=$(sed -E 's#.*/(if/flow|api/v3/flows/executor)/([^/?]+)/?.*#\2#' <<<"$loc_abs")
        q=$(_ol_query "$loc_abs")
        to=$(_ol_executor "$jar" "$slug" "$q" "$user" "$pass") || return 1
        url=$(_ol_abs "$to") ;;
      *) url="$loc_abs" ;;
    esac
  done
  [[ "$callback" == "${cb}"* ]] || { echo "oidc: did not reach Outline's callback (last: ${callback:-${url}})" >&2; return 1; }
  # 6. Outline exchanges the code and sets accessToken.
  curl -sS --socks5-hostname "$PROXY" --max-time 60 -b "$jar" -c "$jar" -o /dev/null "$callback"
  token=$(_ol_jar_cookie "$jar" accessToken)
  [[ -n "$token" ]] || { echo "oidc: Outline did not set accessToken after the callback" >&2; return 1; }
  printf '%s\n' "$token"
}
