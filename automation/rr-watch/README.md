# Red Reactions — 24-Hour Automated Editorial Watch (Pilot)

Local, Windows-only editorial automation. An hourly PowerShell watcher collects candidate
entertainment/gaming/anime/comics/trailer news from free RSS/Atom feeds, filters out anything
not genuinely new with cheap deterministic checks, and — **only when there is something new to
evaluate** — invokes your existing Claude Code CLI login **once** to classify it, optionally
write/build/commit/push a very narrow class of strictly-eligible factual articles, and draft
(never post) social copy.

No paid APIs. No `ANTHROPIC_API_KEY`/Anthropic API billing. No X/Facebook API. Uses your existing
Claude Code subscription/login, your existing Git/GitHub workflow, and your existing Cloudflare
deployment from `main`.

**Ships in DRY RUN, INACTIVE by default.** Nothing is committed, pushed, or published until you
explicitly run `enable-pilot.ps1`.

## How it works

```
Task Scheduler (hourly)
  -> watch.ps1
       -> collect.ps1   (fetch RSS/Atom feeds — no AI)
       -> filter.ps1    (drop already-seen/stale/duplicate/non-English — no AI)
       -> if zero new candidates: exit, Claude never starts
       -> run-claude.ps1 (ONE non-interactive Claude Code invocation with the batch)
            -> Claude classifies, checks the repo for duplicates, and — only if
               pilot mode is "live", the pilot is active, and the 10-article cap
               isn't reached — writes/builds/commits/pushes a strictly-eligible article
               and verifies it live, per prompts/editorial-evaluation.md
       -> results merged into pilot.json / queue.json / logs/run-*.log
```

Claude is never left running between hours. Each scheduled run is a fresh, short-lived process.

## Files

| File | Purpose |
|---|---|
| `config.json` | Tunable settings (thresholds, commands, timeouts) |
| `sources.json` | RSS/Atom feeds — toggle `enabled` per feed |
| `pilot.json` | Pilot state: mode, window, counters — the authoritative safety gate |
| `state.json` | Seen-candidate cache (dedup) |
| `queue.json` | Manual-review queue — nothing is ever discarded |
| `prompts/editorial-evaluation.md` | The permanent instructions given to Claude every run |
| `logs/run-*.log` | Human-readable per-run log |
| `logs/final-report-*.md` | 24-hour pilot summary, generated automatically at expiry |

## Commands

**Check status**
```powershell
.\automation\rr-watch\status.ps1
```

**Run one dry run manually** (does this first, before installing anything)
```powershell
.\automation\rr-watch\run-pilot.ps1 -DryRun
```

**Install the hourly scheduled task** (watch-mode only; does not enable publishing)
```powershell
.\automation\rr-watch\install-task.ps1
```

**Remove the hourly scheduled task**
```powershell
.\automation\rr-watch\remove-task.ps1
```

**Enable the 24-hour live pilot** (up to 10 auto-publications; asks for typed confirmation)
```powershell
.\automation\rr-watch\enable-pilot.ps1
```

**Disable live publishing immediately (emergency stop)**
```powershell
.\automation\rr-watch\disable-pilot.ps1
```

**View logs**
```powershell
Get-ChildItem .\automation\rr-watch\logs\run-*.log | Sort-Object LastWriteTime -Descending
```

**View the manual-review queue**
```powershell
Get-Content .\automation\rr-watch\queue.json | ConvertFrom-Json | Select -Expand items
```

**Check the final 24h report** (also written automatically when the pilot expires)
```powershell
Get-ChildItem .\automation\rr-watch\logs\final-report-*.md | Sort-Object LastWriteTime -Descending | Select -First 1
```

## Important notes

- **The computer must be awake and you must be logged in** for the hourly scheduled task to run —
  it's a per-user task (`LogonType Interactive`), not a SYSTEM service, so it never needs a
  stored password.
- **Claude usage only happens inside `run-claude.ps1`**, and only when `watch.ps1` found genuinely
  new candidates after filtering. A quiet hour costs nothing.
- If `ANTHROPIC_API_KEY` is set in your environment, `run-claude.ps1` logs a loud warning — this
  pilot does not use it and is not designed to depend on it.
- If Claude Code is unavailable (not on PATH, times out, or reports a usage/rate limit), the
  batch is preserved in `queue.json` with `status: "pending-retry"` and retried automatically on
  the next scheduled run — nothing is silently dropped.
- The 24-hour window and 10-article cap are enforced in two places: `pilot.json` (checked and
  updated by PowerShell, which is what Claude is told) and inside Claude's own instructions
  (`prompts/editorial-evaluation.md`), which refuses to act outside those bounds. PowerShell also
  hard-caps how many of Claude's reported publications it will count, in case of a discrepancy.
- Social copy is always just **drafted** into the run log — nothing is ever posted to X or
  Facebook by this system.
