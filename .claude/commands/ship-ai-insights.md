---
description: Push current work to the active ai-insights branch, run Build Trio workflow, monitor to completion, fix on failure, retry until green.
argument-hint: "[optional commit message]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, WebFetch
---

# /ship-ai-insights — Push to the active ai-insights branch and babysit GitHub Actions build

You are running the **ship-ai-insights** workflow. Goal: get current work onto the active ai-insights branch and produce a green build on `4. Build Trio` GitHub Actions workflow. Retry-on-failure is automatic — keep iterating until green OR until you hit a blocker you cannot resolve without the user.

## Active branch

There are two long-lived experiment branches: `feature/ai-insights` (lean) and `feature/ai-insights+oref-swift` (oref-swift merged in). **The current default build branch is `feature/ai-insights+oref-swift`** — confirm the checked-out branch first and ship to whichever the user is actually on. Never run both builds in parallel: they share `APP_DEV_VERSION 0.8.0` and collide on the TestFlight upload step.

## Inputs

User-supplied commit message (optional): `$ARGUMENTS`. If empty, derive a concise conventional-commit message from the staged/unstaged diff.

## Workflow

### 1. Pre-flight

- `git status` and `git branch --show-current`.
- Ship to the **currently checked-out** ai-insights branch (normally `feature/ai-insights+oref-swift`). Do NOT switch branches. Only ask the user if the checked-out branch is something unexpected (not an ai-insights branch).
- If working tree dirty: stage tracked changes (`git add -u`) plus any obviously-relevant new files. **Never** `git add .` or `-A` (avoids secrets/large bins). Show diff stat before committing.
- If clean and branch already matches remote: skip to step 3 (no-op push, but still trigger build if user explicitly asked).

### 2. Commit + push

- Create a single commit on the active branch (the one currently checked out). Conventional message, no Claude attribution unless requested.
- `git push origin <current-branch>`. If push rejected (non-fast-forward), STOP and ask user — do not force-push. Fork is `pov-it/Trio`.

### 3. Trigger build

- Trigger via: `gh workflow run "4. Build Trio" --repo pov-it/Trio --ref <current-branch>`.
- Capture the run ID: poll `gh run list --workflow="4. Build Trio" --repo pov-it/Trio --branch <current-branch> --limit 1 --json databaseId,status,conclusion,headSha` until `headSha` matches `git rev-parse HEAD`. Up to 30s wait.

### 4. Monitor — MANDATORY, to completion

**This is not optional. Dispatching the build is NOT "done". You MUST watch it to a terminal state (success or failure) and report the outcome.** Past failures of this command have been: triggering the build and then walking away without confirming it went green. Do not do that.

- Preferred: `gh run watch <runId> --repo pov-it/Trio --exit-status` via Bash `run_in_background`. You will be notified when it finishes — do not poll, do not sleep-loop.
- If `gh run watch` is unavailable/unreliable, poll `gh run view <runId> --repo pov-it/Trio --json status,conclusion,jobs`; sleep 270s between polls (stays in cache window). Build is long (~30–60 min).
- Treat the authoritative outcome as `gh run view <runId> --json status,conclusion` (`completed`/`success`). A background watcher reporting a nonzero exit is NOT authoritative on its own — re-check with `gh run view` before declaring failure.
- Stream progress to user every few polls: "Build still running, job X at step Y" — terse. Do NOT end your turn until the build reaches a terminal state and you've reported it.

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
- Re-trigger build (step 3) and go back to step 4 — monitor the new run to completion too. Repeat up to **5 build attempts** total before bailing to user with a summary of what was tried.

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
