#!/usr/bin/env bash
# Uptime watchdog check, run by .github/workflows/watchdog.yml (one link of a self-restarting chain).
#
# The watched server sets the repository variable LAST_HEALTHY_TS (unix seconds) every few minutes
# while it is healthy. This script sends ONE Telegram alert when that timestamp is older than STALE_S
# (or missing), and ONE "back up" message when it is fresh again. The alert state lives in the variable
# ALERT_STATE ("down" after an alert, else "ok"), so it does not repeat every run. Every run also sets
# WATCHDOG_TS (unix seconds), so the server can tell whether this watchdog is still running. It also
# reminds you (once a day, from REMIND_DAYS before) to renew the state token.
#
# Variables are read through the API on every run, not from the workflow's vars context: the chain
# keeps running for days, so a value read at start would be stale.
#
# Environment:
#   STATE_TOKEN      fine-grained token, "Variables: read and write" on this repo only (secret)
#   TG_TOKEN TG_CHAT Telegram API token and chat id (secrets)
#   REPO             owner/name of this repo
#   STALE_S          alert threshold in seconds (repository variable STALE_S; default 2700 = 45 min)
#   FAKE_TS          manual test runs only: use this instead of LAST_HEALTHY_TS
#   NOW API_GITHUB API_TELEGRAM REMIND_DAYS   overrides for tests
#
# Tokens never go on a command line or into the log: curl reads its URL and auth header from a config
# on stdin (-K -). The log shows times and states only. Exit 1 when something failed (message not
# sent, state not saved, token rejected).
set -euo pipefail

STALE_S=${STALE_S:-2700}
[[ $STALE_S =~ ^[0-9]{2,6}$ ]] || STALE_S=2700
REMIND_DAYS=${REMIND_DAYS:-7}
API_GITHUB=${API_GITHUB:-https://api.github.com}
API_TELEGRAM=${API_TELEGRAM:-https://api.telegram.org}
now=${NOW:-$(date -u +%s)}
# a secret pasted with a trailing newline must not break the URL or the header
TG_TOKEN=$(printf '%s' "${TG_TOKEN:-}" | tr -d '[:space:]')
STATE_TOKEN=$(printf '%s' "${STATE_TOKEN:-}" | tr -d '[:space:]')
TG_CHAT=$(printf '%s' "${TG_CHAT:-}" | tr -d '[:space:]')
hdr=$(mktemp)
body=$(mktemp)
trap 'rm -f "$hdr" "$body"' EXIT

log() { echo "watchdog: $*"; }
utc() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; }
dur() { local s=$1; if [ "$s" -ge 3600 ]; then echo "$((s / 3600)) h $((s % 3600 / 60)) min"; else echo "$((s / 60)) min"; fi; }

telegram() {
    local code
    code=$(printf 'url = "%s/bot%s/sendMessage"\n' "$API_TELEGRAM" "$TG_TOKEN" |
        curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -K - \
            --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$1") || code=000
    if [ "$code" != 200 ]; then log "Telegram send failed (HTTP $code)"; return 1; fi
    log "Telegram message sent"
}

# github METHOD PATH [JSON] -> prints the HTTP status (000 on a network error); headers go to $hdr,
# the response body to $body
github() {
    local args=(-sS -o "$body" -D "$hdr" -w '%{http_code}' --max-time 10 -X "$1" -K -)
    if [ -n "${3:-}" ]; then args+=(-H 'Content-Type: application/json' --data "$3"); fi
    : >"$body"
    printf 'url = "%s%s"\nheader = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' \
        "$API_GITHUB" "$2" "$STATE_TOKEN" | curl "${args[@]}" || echo 000
}

# get_var NAME -> prints the variable's value ("" when it does not exist or cannot be read)
get_var() {
    local code
    code=$(github GET "/repos/$REPO/actions/variables/$1")
    # values are digits, ok/down or a date: no quotes or backslashes to unescape
    if [ "$code" = 200 ]; then tr -d '\n' <"$body" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p'; fi
}

set_var() {
    local data code
    [[ $2 =~ ^[A-Za-z0-9_.:-]*$ ]] || { log "refusing to set $1 to an unexpected value"; return 1; }
    data=$(printf '{"name":"%s","value":"%s"}' "$1" "$2")
    code=$(github PATCH "/repos/$REPO/actions/variables/$1" "$data")
    if [ "$code" = 404 ]; then code=$(github POST "/repos/$REPO/actions/variables" "$data"); fi
    case $code in
        201|204) log "set $1" ;;
        *) log "could not set $1 (HTTP $code)"; return 1 ;;
    esac
}

# ok | bad (token rejected) | unknown (GitHub unreachable); also sends the expiry reminder.
check_token() {
    local code exp exp_s days today
    code=$(github GET "/repos/$REPO/actions/variables?per_page=1")
    case $code in
        200) ;;
        401|403) echo bad; return ;;
        *) log "GitHub API check failed (HTTP $code)" >&2; echo unknown; return ;;
    esac
    exp=$(grep -i '^github-authentication-token-expiration:' "$hdr" | head -n 1 | cut -d: -f2- | tr -d '\r' || true)
    exp_s=$(date -u -d "$exp" +%s 2>/dev/null || true)
    if [ -z "$exp" ] || [ -z "$exp_s" ]; then log "state token: no expiry date reported" >&2; echo ok; return; fi
    days=$(((exp_s - now) / 86400))
    log "state token expires in $days days" >&2
    today=$(date -u -d "@$now" +%F)
    if [ "$days" -lt "$REMIND_DAYS" ] && [ "$(get_var TOKEN_REMINDED)" != "$today" ]; then
        if telegram "Uptime watchdog: the state token expires in $days days ($(utc "$exp_s")). Renew it: see the mac-uptime-watchdog README, 'Renew the state token'." >&2; then
            set_var TOKEN_REMINDED "$today" >&2 || true
        fi
    fi
    echo ok
}

rc=0
token=$(check_token)
if [ "$token" = bad ]; then
    log "::error::the state token was rejected. Expired or revoked? Renew it: README 'Renew the state token'"
    # No state can be saved without the token, so limit this message to the 14:xx UTC runs.
    if [ "$(date -u -d "@$now" +%H)" = 14 ] && [ "$(date -u -d "@$now" +%M)" -lt 15 ]; then
        telegram "Uptime watchdog: the state token was REJECTED (expired or revoked?). The server cannot report and the watchdog cannot track its state, so it is blind until you renew the token (mac-uptime-watchdog README, 'Renew the state token')." || true
    fi
    exit 1
fi

ts=""
state=ok
if [ "$token" = ok ]; then
    ts=$(get_var LAST_HEALTHY_TS)
    state=$(get_var ALERT_STATE)
    state=${state:-ok}
    set_var WATCHDOG_TS "$now" || rc=1
fi
if [ -n "${FAKE_TS:-}" ]; then
    log "manual test run: using the fake LAST_HEALTHY_TS=$FAKE_TS"
    ts=$FAKE_TS
fi
if [[ $ts =~ ^[0-9]{1,12}$ ]]; then
    age=$((now - ts))
    last="last healthy $(utc "$ts"), $(dur $((age > 0 ? age : 0))) ago"
    if [ "$age" -le "$STALE_S" ]; then healthy=1; else healthy=0; fi
elif [ "$token" = unknown ] && [ -z "${FAKE_TS:-}" ]; then
    log "GitHub unreachable: cannot read the heartbeat; no message this run"
    exit 1
else
    healthy=0
    last="no valid heartbeat recorded"
fi
log "$last; threshold $((STALE_S / 60)) min; state $state"

if [ "$healthy" = 0 ] && [ "$state" != down ]; then
    if telegram "Uptime watchdog: server DOWN or unhealthy - $last. (No heartbeat for over $((STALE_S / 60)) min.) Check the server and its heartbeat log."; then
        set_var ALERT_STATE down || rc=1
    else
        rc=1
    fi
elif [ "$healthy" = 1 ] && [ "$state" = down ]; then
    if telegram "Uptime watchdog: server back up - $last."; then
        set_var ALERT_STATE ok || rc=1
    else
        rc=1
    fi
else
    log "no message (healthy=$healthy, state=$state)"
fi
exit $rc
