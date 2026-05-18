---
description: Push current work to feature/ai-insights, run Build Trio workflow, monitor, fix on failure, retry until green.
argument-hint: "[optional commit message]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, WebFetch
---

# /ship-ai-insights — Push to feature/ai-insights and babysit GitHub Actions build

You are running the **ship-ai-insights** workflow. Goal: get current work onto `feature/ai-insights` and produce a green build on `4. Build Trio` GitHub Actions workflow. Retry-on-failure is automatic — keep iterating until green OR until you hit a blocker you cannot resolve without the user.

## Inputs

User-supplied commit message (optional): `$ARGUMENTS`. If empty, derive a concise conventional-commit message from the staged/unstaged diff.

## Workflow

### 1. Pre-flight

- `git status` and `git branch --show-current`.
- If branch ≠ `feature/ai-insights`: ask user before switching. They may want changes shipped via a different branch first (e.g. they are on a worktree branch and want it merged forward).
- If working tree dirty: stage tracked changes (`git add -u`) plus any obviously-relevant new files. **Never** `git add .` or `-A` (avoids secrets/large bins). Show diff stat before committing.
- If clean and branch already matches remote: skip to step 3 (no-op push, but still trigger build if user explicitly asked).

### 2. Commit + push

- Create a single commit on `feature/ai-insights` (or current branch if user redirected). Conventional message, no Claude attribution unless requested.
- `git push origin feature/ai-insights`. If push rejected (non-fast-forward), STOP and ask user — do not force-push. Fork is `pov-it/Trio`.

### 3. Trigger build

- Trigger via: `gh workflow run "4. Build Trio" --repo pov-it/Trio --ref feature/ai-insights`.
- Capture the run ID: poll `gh run list --workflow="4. Build Trio" --repo pov-it/Trio --branch feature/ai-insights --limit 1 --json databaseId,status,conclusion,headSha` until `headSha` matches `git rev-parse HEAD`. Up to 30s wait.

### 4. Monitor

- Poll run status with `gh run view <runId> --repo pov-it/Trio --json status,conclusion,jobs` every ~120s.
- Build is long (~30–60 min). Use Bash `run_in_background` only if appropriate; otherwise just sleep 270s between polls (stays in cache window).
- Stream progress to user every 2–3 polls: "Build still running, job X at step Y" — terse.

### 5. On success

- Confirm to user: run URL + duration. Done.

### 6. On failure

- `gh run view <runId> --repo pov-it/Trio --log-failed > /tmp/run-<runId>.log` (or PowerShell equivalent — write to a temp file, then Grep for `error:`, `FAILED`, `xcodebuild`, etc.). Logs can be huge; do NOT cat raw into context.
- Identify failing job and step. Extract the actual error (usually Swift compile error, missing symbol, missing entitlement, submodule sync issue, signing).
- **Diagnose root cause.** Common Trio build failures:
  - Swift 6 strict concurrency: actor isolation, non-Sendable captures. Fix in source.
  - Missing Xcode project refs after adding files: edit `Trio.xcodeproj/project.pbxproj` carefully, or move file under an existing group.
  - Submodule SHA mismatch: check `git submodule status`.
  - Localization key duplication: run `Scripts/check.py` if present.
  - Signing/secrets in GH Actions: NOT your fix — surface to user.
  - Browser build specifics: see https://loopkit.github.io/loopdocs/browser/edit-browser/ — fetch if relevant.
- Edit code locally. Do NOT skip hooks. Re-commit ("fix: <what>") and push.
- Re-trigger build (step 3). Repeat up to **5 build attempts** total before bailing to user with a summary of what was tried.

### 7. Bail conditions

Stop and surface to the user if any of these hit — do not keep trying:

- Failure root cause is in CI infra (GH Actions secrets, runner availability, GH_PAT scope) rather than code.
- Same error recurs after 2 fix attempts on the same file — your hypothesis is wrong, get human input.
- Fix would require destructive git ops (force-push, history rewrite) or modifying CI workflow YAML for non-trivial reasons.
- 5 build attempts reached.

## Notes

- This command runs on **Windows / PowerShell**. Prefer PowerShell tool for shell ops; Bash works too but quote carefully.
- Build runs on GitHub Actions ubuntu runner — Linux-specific quirks may not reproduce locally. Macros, signing, etc. require the actual CI run to validate.
- Loop docs link for browser-build context: https://loopkit.github.io/loopdocs/browser/edit-browser/ — useful when the failure is signing/identifiers/entitlement-related.
- Reference workflow file: `.github/workflows/build_trio.yml`.

## Caveman mode

This command's instructions are normal prose (multi-step procedure — readability matters). When narrating progress to the user during execution, default to caveman style: `[thing] [action] [reason]. [next step].` Drop articles/filler.
