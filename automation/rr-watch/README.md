# Red Reactions — 24-Hour Automated Editorial Watch (Pilot)

Local, Windows-only editorial automation. An hourly PowerShell watcher collects candidate
entertainment/gaming/anime/comics/trailer news from free RSS/Atom feeds, filters out anything
not genuinely new with cheap deterministic checks, and — **only when there is something new to
evaluate** — invokes your existing Claude Code CLI login to classify it in a read-only
evaluation phase, then (only in live mode, only after PowerShell independently re-verifies every
safety gate immediately beforehand, and only one at a time) invokes a separately-scoped
publisher phase to write/build/commit/push a very narrow class of strictly-eligible factual
articles, and draft (never post) social copy.

No paid APIs. No `ANTHROPIC_API_KEY`/Anthropic API billing, no Bedrock, no Vertex, no Foundry —
every Claude child process has those routing variables stripped from its own environment before
it starts. No X/Facebook API. Uses your existing Claude Code subscription/login, your existing
Git/GitHub workflow, and your existing Cloudflare deployment from `main`.

**Ships in DRY RUN, INACTIVE by default.** Nothing is committed, pushed, or published until you
explicitly run `enable-pilot.ps1` — and even then, PowerShell re-checks the live gate itself
before every single article, not just at the start of an hourly run.

## How it works

Claude is the **last**, most expensive filter — not the first meaningful one. Most hourly runs
should invoke it zero times.

```
Task Scheduler (hourly)
  -> watch.ps1
       -> collect.ps1     (fetch RSS/Atom feeds — no AI)
       -> filter.ps1      (drop already-seen/stale/duplicate/non-English — no AI)
       -> prioritize.ps1  (relevance-rules.json: reject noise, score by keywords/franchise/
                            source-tier/breaking-news combos, rank, cap to
                            config.maxCandidatesPerClaudeRun — no AI)
       -> if nothing strong survives, or the daily evaluator-call cap is reached: exit,
          Claude never starts. Anything strong that didn't fit this run's cap is queued
          (status "strong-overflow") for a later run — never discarded.
       -> PHASE A — Invoke-RREvaluator (run-claude.ps1), AT MOST ONCE per run
            ONE Claude Code invocation, restricted to Claude Code's read-only "plan"
            permission mode: it can read/search the repo and research, but has no file-write,
            git, or side-effecting bash capability. Given a small deterministically-generated
            existing-content index (generate-content-index.ps1) for fast duplicate triage —
            not a repo-wide search. Classifies every candidate; recommends which are
            auto-eligible. Never has publish capability, dry-run or live.
       -> if forced -DryRun, or pilot.json isn't live+active: STOP HERE.
          Auto-eligible items are queued for the owner to review; nothing is published.
       -> PHASE B — Invoke-RRPublisher (run-claude.ps1), once PER eligible candidate
            Before EACH invocation, watch.ps1 re-reads pilot.json from disk and re-checks
            mode==live, active==true, not expired, autoPublishedCount < cap. Only if all of
            that is true right now does it start a publisher process — with write/git/build
            capability — scoped to exactly that one candidate. The moment any check fails,
            no further publisher process starts for the rest of that run.
       -> results merged into pilot.json / queue.json / logs/run-*.log
```

Claude is never left running between hours, evaluator calls are capped both per-run (batch size)
and per-24h-window (`maxEvaluatorClaudeRunsPer24h`), and the evaluator is never capable of
publishing regardless of pilot mode — only the narrowly-scoped, individually-gated publisher can.

## Files

| File | Purpose |
|---|---|
| `preflight.ps1` | Runtime/auth check — run before baseline and before enabling live |
| `initialize-baseline.ps1` | One-time: marks current feed inventory as seen, no Claude |
| `config.json` | Tunable settings (thresholds, commands, timeouts, batch/daily Claude caps) |
| `sources.json` | RSS/Atom feeds — toggle `enabled` per feed, `tier` drives priority scoring |
| `relevance-rules.json` | Positive/negative keywords, franchises, breaking-news combos, scoring |
| `prioritize.ps1` | Deterministic relevance/priority scoring — the pre-Claude gate — no AI |
| `generate-content-index.ps1` | Builds the lightweight existing-article index from MDX frontmatter — no AI |
| `pilot.json` | Pilot state: mode, window, counters — the **single** authoritative safety gate |
| `state.json` | Seen-candidate cache (dedup) + baseline timestamp |
| `queue.json` | Manual review / retry-backoff / batch-overflow queue — nothing is ever discarded |
| `prompts/editorial-evaluation.md` | Phase A instructions — evaluation only, no publish |
| `prompts/publish-single-article.md` | Phase B instructions — exactly one article, full access |
| `logs/run-*.log` | Human-readable per-run log |
| `logs/final-report-*.md` | 24-hour pilot summary, generated automatically at expiry |
| `logs/preflight-last.json` | Last preflight result |

`pilot.json`'s `mode`/`active` fields are the **only** place dry-run-vs-live state lives.
`config.json` deliberately has no separate `dryRun` flag — a second copy of that state
previously existed there unused, which risked going out of sync with `pilot.json`; it has been
removed rather than wired in, since `pilot.json` already needs to be richer (start/end time,
counters) to do its job.

## Commands — recommended first-time order

**1. Preflight** (runtime, PATH, and subscription-auth check; run again before enabling live)
```powershell
.\automation\rr-watch\preflight.ps1
```
Then, separately and manually — this script cannot do it for you — run `claude`, and inside it
run `/status`, and confirm the authenticated account shown is your Claude subscription login,
not an API key.

**2. Baseline** (run once, before the first real dry run, so the first run doesn't dump up to
`candidateMaxAgeHours` of backlog into a single Claude invocation)
```powershell
.\automation\rr-watch\initialize-baseline.ps1
```

**3. Manual dry run**
```powershell
.\automation\rr-watch\run-pilot.ps1 -DryRun
```

**4. Inspect the result**
```powershell
Get-ChildItem .\automation\rr-watch\logs\run-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
Get-Content .\automation\rr-watch\queue.json | ConvertFrom-Json | Select-Object -Expand items
```

**5. Install the hourly scheduled task** (watch-mode only; does not enable publishing)
```powershell
.\automation\rr-watch\install-task.ps1
```

**6. Only once you're satisfied — enable the 24-hour live pilot** (up to 10 auto-publications;
asks for typed confirmation)
```powershell
.\automation\rr-watch\enable-pilot.ps1
```

**Emergency stop — disable live publishing immediately**
```powershell
.\automation\rr-watch\disable-pilot.ps1
```

**Remove the hourly scheduled task**
```powershell
.\automation\rr-watch\remove-task.ps1
```

**Check status**
```powershell
.\automation\rr-watch\status.ps1
```

**View the manual-review queue**
```powershell
Get-Content .\automation\rr-watch\queue.json | ConvertFrom-Json | Select-Object -Expand items
```

**Check the final 24h report** (also written automatically when the pilot expires)
```powershell
Get-ChildItem .\automation\rr-watch\logs\final-report-*.md | Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

## Important notes

- **The computer must be awake and you must be logged in** for the hourly scheduled task to run —
  it's a per-user task (`LogonType Interactive`), not a SYSTEM service, so it never needs a
  stored password. `install-task.ps1` uses `pwsh.exe` if present, otherwise `powershell.exe`;
  `preflight.ps1` reports which one your machine will actually use.
- **Claude usage only happens inside `run-claude.ps1`**, and only when at least one candidate
  survives ALL of: seen/stale/dedup filtering, `relevance-rules.json` noise rejection and
  tier/keyword/breaking-news scoring, AND the per-24h evaluator-call cap
  (`maxEvaluatorClaudeRunsPer24h`, default 8) hasn't been reached. A quiet hour — or an hour where
  nothing strong enough appeared — costs nothing. `status.ps1` reports zero-Claude-run counts,
  feed items removed deterministically, strong-candidate counts, and Claude call counts so you
  can see this working. Tune `relevance-rules.json` and `sources.json`'s per-feed `tier` freely —
  no code changes needed.
- **A candidate is never retried blindly every hour.** Failed evaluator/publisher attempts get
  `retryCount`/`nextRetryAt` backoff (`config.retryBackoffHours`, longer for a detected
  usage/rate limit via `usageLimitBackoffHours`) before they're eligible again. Strong candidates
  that didn't fit a run's `maxCandidatesPerClaudeRun` cap are queued as `strong-overflow` and
  picked up by a later run once there's room — also never discarded.
- **API-key/Bedrock/Vertex/Foundry billing is actively prevented, not just discouraged**: every
  Claude child process is started with those environment variables stripped from its own
  environment (never from your shell, never from Windows) before it starts, and no value is ever
  logged — only variable names, when something was stripped. If subscription auth can't be
  confirmed (`preflight.ps1` fails), treat the live pilot as not ready.
- If Claude Code is unavailable (not on PATH, times out, or reports a usage/rate limit), the
  batch is preserved in `queue.json` with `status: "pending-retry"` and retried automatically on
  the next scheduled run — nothing is silently dropped, and no billing fallback is ever attempted.
- **The evaluator (Phase A) never has publish capability**, in dry-run or live mode — it runs in
  Claude Code's restricted read-only "plan" permission mode. Only the publisher (Phase B), which
  handles exactly one candidate per invocation and is only ever started after PowerShell has
  freshly re-read `pilot.json` and re-checked mode/active/expiry/remaining-cap, has write/git
  capability. `--dangerously-skip-permissions` is never used by this automation; if your local
  Claude Code CLI version turns out to require it for the publisher to run non-interactively,
  that is a blocker to resolve manually, not something this automation enables for you.
- The 24-hour window and 10-article cap are enforced by `pilot.json`, re-read fresh from disk
  immediately before every individual publisher invocation — not just once per hourly run.
- Social copy is always just **drafted** into the run log — nothing is ever posted to X or
  Facebook by this system.
