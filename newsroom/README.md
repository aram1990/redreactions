# Red Reactions newsroom

`node scripts/newsroom/run.mjs` researches, verifies, writes and validates at most two news articles. It is deliberately fail-closed: a missing primary source, a questionable image, a duplicate, invalid metadata, broken internal link, non-clean build, or unexpected Git change prevents publication.

The scheduled workflow is enabled by default for the one-day test. To pause scheduled runs without removing the newsroom, set the repository variable `RED_REACTIONS_NEWSROOM_SCHEDULE_ENABLED` to `false`. Manual `workflow_dispatch` runs remain available.

## Required secret

- `OPENAI_API_KEY` — used only by the newsroom to perform web-backed discovery, verification and drafting through the Responses API.

## Optional repository variables

- `RED_REACTIONS_NEWSROOM_MODEL` — model name; defaults to `gpt-5-mini`.
- `RED_REACTIONS_NEWSROOM_APPROVED_IMAGE_HOSTS` — comma-separated extra official image hosts. The default allowlist covers common studio, streamer, publisher, platform and Wikimedia hosts. Use this only for a verified official asset host.

`state.json` is intentionally small. It keeps recently published source URLs and slugs for duplicate protection, plus compact run summaries. It retains only the most recent 50 entries of each type.
