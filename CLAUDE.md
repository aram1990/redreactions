# Claude Code Instructions — Red Reactions

Repository-wide instructions for Claude Code sessions working in this repo. These apply automatically to every session; do not create a second, competing instructions file (e.g. `AGENTS.md`) — extend this one instead.

## Permanent Production Publishing Rule

Production deploys from `main`. Cloudflare deploys automatically from `main`. A push to a `claude/*`, feature, session, or temporary branch is **not** publication, and must never be reported as PUBLISHED.

For every completed article/content publishing task:

1. Work safely and inspect the current Git state first.
2. Research/verify/write/add approved images as required.
3. Run the required checks/build (`npm run check`, `npm run build`).
4. Commit only approved task files — never broadly stage unrelated files (no research dumps, temp files, README/NOTES, unused assets, or unrelated site changes).
5. Integrate the completed work into local `main`.
6. Push specifically to `origin/main`.
7. Never force push.
8. Verify local `main` and `origin/main` match after pushing.
9. Verify the actual production URL on `https://redreactions.com` is live and correct.
10. Verify title, canonical URL, hero/og:image and relevant metadata on production.

If Claude Code begins work on a temporary/session branch, that's fine during the task — but before the task is complete, safely integrate ONLY the approved task work into `main` and push `origin/main`. Do not leave completed, approved articles stranded on a Claude branch.

**If `main` cannot be updated safely** — conflicts, unrelated changes mixed into the branch, a failed build/check, uncertain Git state, or any other red flag — **stop before pushing and report the exact problem** instead of forcing it through.

### Definition of PUBLISHED

Only report an article as PUBLISHED once all of the following are true:

- Approved files committed.
- Work integrated into `main`.
- Validation passed (`npm run check` and `npm run build`, 0 errors/0 warnings/0 hints).
- `origin/main` successfully updated.
- Production deployment verified.
- The production article URL returns successfully and contains the expected article.
- Social preview metadata/og:image verified when applicable.

Anything short of this is in-progress work, not a published article — report it as such.
