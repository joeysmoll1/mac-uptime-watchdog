#!/usr/bin/env bash
# Local tests for watchdog.sh: alert, no-spam, recovery, WATCHDOG_TS, token checks. No network: a fake
# `curl` on PATH answers for Telegram and GitHub and logs every call. Repository variables are served
# from the environment of the test run (unset = 404). Run: bash tests/test_watchdog.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../watchdog.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: reads the -K - config from stdin, logs "METHOD URL auth=N DATA...", writes a body to -o,
# headers to -D, and prints a status code.
cfg=$(cat)
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' <<<"$cfg")
auth=$(grep -c '^header = "Authorization: Bearer ' <<<"$cfg")
method=; hdr=; out=/dev/null; data=()
while [ $# -gt 0 ]; do
    case $1 in
        -X) method=$2; shift ;;
        -D) hdr=$2; shift ;;
        -o) out=$2; shift ;;
        --data|--data-urlencode) data+=("$2"); shift ;;
        -w|--max-time|-H|-K) shift ;;
    esac
    shift
done
[ -n "$method" ] || { [ ${#data[@]} -gt 0 ] && method=POST || method=GET; }
echo "$method $url auth=$auth ${data[*]}" >>"$FAKE_LOG"
case $url in
    */sendMessage) code=${FAKE_TG:-200} ;;
    *"/actions/variables?per_page=1")
        code=${FAKE_AUTH:-200}
        [ -n "$hdr" ] && printf 'HTTP/2 %s\r\n%s\r\n' "$code" \
            "${FAKE_EXP:+github-authentication-token-expiration: $FAKE_EXP}" >"$hdr" ;;
    */actions/variables/*)
        name=${url##*/}
        if [ "$method" = GET ]; then
            if [ -n "${!name+x}" ]; then
                code=200
                printf '{\n  "name": "%s",\n  "value": "%s",\n  "created_at": "x"\n}\n' "$name" "${!name}" >"$out"
            else
                code=404
            fi
        else
            code=${FAKE_PATCH:-204}
        fi ;;
    *) code=201 ;;
esac
[ "$code" = 000 ] && exit 6
printf '%s' "$code"
EOF
chmod +x "$WORK/bin/curl"

NOW_TS=1792560000            # 2026-10-21 05:20 UTC
TODAY=$(date -u -d "@$NOW_TS" +%F)
TOKEN_TG="123456:FAKE-TG-TOKEN-xyz"
TOKEN_STATE="github_pat_FAKE_STATE_TOKEN_abc"
pass=0; fail=0

# run [VAR=value ...]: runs watchdog.sh with defaults + overrides; sets OUT, RC, CALLS
run() {
    : >"$WORK/log"
    OUT=$(env -i PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/log" NOW=$NOW_TS REPO=me/watch \
        TG_TOKEN="$TOKEN_TG" TG_CHAT=42 STATE_TOKEN="$TOKEN_STATE" \
        FAKE_EXP="2027-01-19 08:00:00 UTC" "$@" bash "$SCRIPT" 2>&1)
    RC=$?
    CALLS=$(cat "$WORK/log")
}
sends() { grep -c 'sendMessage' <<<"$CALLS"; }
# shellcheck disable=SC2001  # sed indents multi-line output
check() { # name condition...
    local name=$1; shift
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; echo "$OUT" | sed 's/^/    | /'; echo "$CALLS" | sed 's/^/    > /'; fi
}
no_token_in_output() { ! grep -q -e "$TOKEN_TG" -e "$TOKEN_STATE" <<<"$OUT"; }
has() { grep -q -- "$1" <<<"$CALLS"; }
lacks() { local p a=(); for p in "$@"; do a+=(-e "$p"); done; ! grep -q "${a[@]}" <<<"$CALLS"; }
no_token_in_calls() { ! grep -v sendMessage <<<"$CALLS" | grep -q -e FAKE-TG -e github_pat; }
state_writes() { grep -c 'actions/variables/ALERT_STATE auth=1 {' <<<"$CALLS"; }

fresh=$((NOW_TS - 300)); stale=$((NOW_TS - 3600))

run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok
check "healthy + ok: silent" test "$(sends)" = 0 -a "$RC" = 0
check "healthy + ok: no ALERT_STATE write" test "$(state_writes)" = 0
check "every run: WATCHDOG_TS set to now" has "PATCH .*/repos/me/watch/actions/variables/WATCHDOG_TS auth=1 {\"name\":\"WATCHDOG_TS\",\"value\":\"$NOW_TS\"}"
check "variables read through the API" has 'GET .*/repos/me/watch/actions/variables/LAST_HEALTHY_TS auth=1'

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok
check "stale: one alert" test "$(sends)" = 1 -a "$RC" = 0
check "stale: alert says DOWN" has 'text=Uptime watchdog: server DOWN'
check "stale: state saved as down" has 'PATCH .*/actions/variables/ALERT_STATE auth=1 {"name":"ALERT_STATE","value":"down"}'
check "stale: tokens not printed" no_token_in_output
# shellcheck disable=SC2088  # a literal ~/ that must not appear in the message
check "stale: no commands or paths in the message" lacks 'ssh ' '~/'

run LAST_HEALTHY_TS=$stale ALERT_STATE=down
check "still down: no repeat alert (no spam)" test "$(sends)" = 0 -a "$RC" = 0

run LAST_HEALTHY_TS=$fresh ALERT_STATE=down
check "recovered: one back-up message" test "$(sends)" = 1 -a "$RC" = 0
check "recovered: text" has 'text=Uptime watchdog: server back up'
check "recovered: state saved as ok" has '"name":"ALERT_STATE","value":"ok"'

run ALERT_STATE=ok
check "missing timestamp: alert" test "$(sends)" = 1
check "missing timestamp: says no heartbeat" has 'no valid heartbeat recorded'

run LAST_HEALTHY_TS=$stale
check "missing ALERT_STATE counts as ok: alert" test "$(sends)" = 1

run LAST_HEALTHY_TS=garbage ALERT_STATE=ok
check "non-numeric timestamp: alert" test "$(sends)" = 1

run LAST_HEALTHY_TS=$((NOW_TS - 2700)) ALERT_STATE=ok
check "exactly 45 min old: still healthy" test "$(sends)" = 0
run LAST_HEALTHY_TS=$((NOW_TS - 2701)) ALERT_STATE=ok
check "45 min + 1 s: alert" test "$(sends)" = 1

run LAST_HEALTHY_TS=$((NOW_TS - 1200)) ALERT_STATE=ok STALE_S=1200
check "STALE_S 1200: exactly 20 min still healthy" test "$(sends)" = 0
run LAST_HEALTHY_TS=$((NOW_TS - 1201)) ALERT_STATE=ok STALE_S=1200
check "STALE_S 1200: 20 min + 1 s alerts" test "$(sends)" = 1
run LAST_HEALTHY_TS=$((NOW_TS - 2701)) ALERT_STATE=ok STALE_S='1; rm -rf /'
check "bad STALE_S falls back to 45 min" test "$(sends)" = 1 -a "$RC" = 0
run LAST_HEALTHY_TS=$((NOW_TS - 2000)) ALERT_STATE=ok STALE_S=
check "empty STALE_S (variable unset) is 45 min" test "$(sends)" = 0

run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok FAKE_TS=1
check "manual fake old timestamp: alert" test "$(sends)" = 1
check "manual fake: logged" grep -q 'manual test run' <<<"$OUT"

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok FAKE_TG=500
check "Telegram fails: exit 1" test "$RC" = 1
check "Telegram fails: state NOT saved (retry next run)" test "$(state_writes)" = 0

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok FAKE_TG=000
check "Telegram unreachable: exit 1" test "$RC" = 1
check "Telegram unreachable: no state" test "$(state_writes)" = 0

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok FAKE_PATCH=404
check "variable missing: created with POST" has 'POST .*/repos/me/watch/actions/variables auth=1 {"name":"ALERT_STATE"'
check "variable missing: exit 0" test "$RC" = 0

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok FAKE_PATCH=500
check "state save fails: exit 1" test "$RC" = 1

exp3=$(date -u -d "@$((NOW_TS + 3 * 86400 + 600))" '+%Y-%m-%d %H:%M:%S UTC')
run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok FAKE_EXP="$exp3"
check "token expires in 3 days: one reminder" test "$(sends)" = 1
check "token reminder text" has 'expires in 3 days'
check "token reminder: date saved" has "\"name\":\"TOKEN_REMINDED\",\"value\":\"$TODAY\""
run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok FAKE_EXP="$exp3" TOKEN_REMINDED="$TODAY"
check "token reminder: once a day" test "$(sends)" = 0
run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok
check "token far from expiry: no reminder" test "$(sends)" = 0
check "token expiry logged as days only" grep -q 'state token expires in [0-9]* days' <<<"$OUT"
no_date_in_output() { ! grep -q '2027-01-19' <<<"$OUT"; }
check "log has no expiry date" no_date_in_output

run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok FAKE_AUTH=401
check "token rejected: exit 1" test "$RC" = 1
check "token rejected outside 14:00-14:14 UTC: no message" test "$(sends)" = 0
run LAST_HEALTHY_TS=$fresh ALERT_STATE=ok FAKE_AUTH=401 NOW=$((NOW_TS + 8 * 3600 + 40 * 60))  # 14:00 UTC
check "token rejected at 14:00 UTC: one message" test "$(sends)" = 1
check "token rejected: tokens not printed" no_token_in_output

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok FAKE_AUTH=000
check "GitHub unreachable: no message (state unknown), exit 1" test "$(sends)" = 0 -a "$RC" = 1

# Full cycle with the state carried between runs: up -> down (1 alert) -> down -> up (1 recovery) -> up
st=ok; total=0
for ts in $fresh $stale $stale $stale $fresh $fresh; do
    run LAST_HEALTHY_TS="$ts" ALERT_STATE="$st"
    total=$((total + $(sends)))
    v=$(sed -n 's/.*ALERT_STATE.*"value":"\([a-z]*\)".*/\1/p' <<<"$CALLS")
    [ -n "$v" ] && st=$v
done
check "full cycle: exactly 2 messages, ends ok" test "$total" = 2 -a "$st" = ok

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok STATE_TOKEN="$TOKEN_STATE"$'\r\n' TG_TOKEN="$TOKEN_TG"$'\n' TG_CHAT=$'42\n'
check "secrets with trailing newlines: exit 0" test "$RC" = 0
check "secrets with trailing newlines: clean URL and chat id" has "bot123456:FAKE-TG-TOKEN-xyz/sendMessage auth=0 chat_id=42 text"

run LAST_HEALTHY_TS=$stale ALERT_STATE=ok
check "every call carries auth via config, not argv" no_token_in_calls

echo "watchdog tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
