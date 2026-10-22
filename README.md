# mac-uptime-watchdog

An outside uptime watchdog for a home server, built only from GitHub Actions and Telegram. The server
reports a heartbeat; this repo alerts once when the heartbeat stops and once when it comes back.
No secrets are stored in this repo.

## How it works

```
server (every 5 min, only when healthy)        this repo (a chain of checks, one every ~10 min)
  --PATCH variable-->  LAST_HEALTHY_TS  <--read--  older than STALE_S (or missing)?
                                                     -> ONE Telegram alert, ALERT_STATE=down
                                                   fresh again and ALERT_STATE=down?
                                                     -> ONE "back up" message, ALERT_STATE=ok
                       WATCHDOG_TS      <--write-- every check (the server checks that it is fresh)
```

- **A chain, not a schedule.** Each run of `.github/workflows/watchdog.yml` waits on the `interval`
  environment's wait timer (10 min), runs `watchdog.sh` once (a few seconds), and starts the next run
  with `workflow_dispatch`. Wait-timer time is not billed and uses no runner, so the chain costs a few
  seconds of runner time per check. GitHub's scheduled runs are delayed or dropped under load, so they
  are not used as the clock.
- **One chain only.** The workflow's concurrency group allows one run in progress and one pending; a
  newer pending run replaces an older one, so extra runs collapse into the one chain.
- **Reviver.** A schedule (`11,41 * * * *`) also starts runs. While the chain is alive they just merge
  into it. If the chain ever stops (a failed dispatch), the next scheduled run GitHub actually starts
  restarts it. Note: GitHub disables schedules in public repos after 60 days without commits; the chain
  itself does not depend on the schedule, and the server warns when `WATCHDOG_TS` goes stale.
- **No spam.** `ALERT_STATE` remembers that the alert was sent. If Telegram is unreachable the state
  is not changed, so the next check tries again.
- **Logs** show times and states only. Secrets are masked by GitHub and never printed: `curl` reads
  URLs and auth headers from a config on stdin.

### Repository settings

| Kind | Name | What |
|---|---|---|
| environment | `interval` | wait timer: 10 min (Settings -> Environments) |
| secret | `TG_TOKEN` | Telegram API token |
| secret | `TG_CHAT` | Telegram chat id that gets the messages |
| secret | `STATE_TOKEN` | fine-grained token, *Variables: read and write* on this repo only (also on the server) |
| variable | `STALE_S` | alert threshold in seconds (default 2700 = 45 min) |
| variable | `LAST_HEALTHY_TS` | written by the server |
| variable | `ALERT_STATE` | `down` after an alert, `ok` otherwise |
| variable | `WATCHDOG_TS` | time of the last check (written by every run) |
| variable | `TOKEN_REMINDED` | date of the last token-expiry reminder |

The workflow's own `GITHUB_TOKEN` gets `contents: read` (checkout) and `actions: write` (start the next
run of this workflow). Actions are pinned to full commit SHAs. Pull requests from forks get no secrets.

## Detection time

A dead server is reported after `STALE_S` plus up to one check interval (10 min) and a short queue
delay: about 20-30 min with `STALE_S=1200`, 45-55 min with the default.

## Manual tests

```bash
# forced alert: pretend the heartbeat is very old -> one DOWN message
gh workflow run watchdog.yml -R OWNER/mac-uptime-watchdog -f fake_last_healthy_ts=1
# normal run: the real heartbeat is fresh -> one "back up" message
gh workflow run watchdog.yml -R OWNER/mac-uptime-watchdog
# break the chain on purpose: this run does not start the next one; the reviver restarts it
gh workflow run watchdog.yml -R OWNER/mac-uptime-watchdog -f stop_chain=true
gh variable list -R OWNER/mac-uptime-watchdog
```

Each manual run also waits the 10 min timer first. Logic tests (no network, a fake `curl`):
`bash tests/test_watchdog.sh`. CI runs them and shellcheck.

## Renew the state token

The fine-grained token expires (90 days). From 7 days before, the watchdog sends a daily Telegram
reminder. When it has expired, the server cannot report, the watchdog cannot track state, and the
workflow fails (with one Telegram message per day, at about 14:00 UTC).

1. github.com -> Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens ->
   open the token -> **Regenerate** (90 days). Check it still has only this repository and
   *Variables: Read and write* (GitHub adds *Metadata: Read-only*; that is expected).
2. Put the new token on the server (its token file) and in the `STATE_TOKEN` secret, without printing
   it, e.g. `gh secret set STATE_TOKEN -R OWNER/mac-uptime-watchdog < token-file`.
3. Run one manual check and look for `state token expires in N days` in its log.

## Cost

Public repository: standard GitHub-hosted runners are free. About 140 checks a day of a few seconds
each; wait-timer time is not billed.
