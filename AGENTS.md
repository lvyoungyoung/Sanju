# Delivery Workflow

User preference confirmed on 2026-09-22:

- When a feature requires a backend update before the user can test it, complete the
  relevant local checks, commit the task's changes, and push to GitHub without waiting
  for another push request. Follow any later explicit instruction to pause pushing.
- After pushing, report the commit and exactly which Edge Functions, migrations or
  proxy settings need deployment. Say explicitly when no new migration is needed.
- Pushing code is not authorization to deploy. Do not trigger staging or production
  deployment unless the user asks. See `docs/backend-release-process.md` for order.
- Never include credentials, build caches or unrelated user changes in an automatic
  task commit. Do not force-push or overwrite remote changes.
