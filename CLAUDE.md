# Trio — project instructions for Claude

## Shipping a build (do this without being asked to re-explain)

When the user wants to "use this version in my build", ship FoodFinder / AI-Insights
work, or otherwise validate that the current code compiles for TestFlight:

1. **Commit** the relevant source on the current feature branch.
   - Always include the Swift app changes under `Trio/Sources/...` — these are what CI compiles.
   - Include FoodFinder lab code (`DeveloperDocs/FoodFinderAgentLab/*.mjs`, `index.html`)
     and findings docs when they are part of the work.
   - **Exclude** bulky eval datasets (`eval/foodbd/`, `*.csv`, `*.pdf`, `*history*.json`,
     `files.json`) — research inputs, not app code; don't bloat the repo.
   - **Exclude** `OmniBLE` / `OmniKit` submodule "modified content" (dirty working trees,
     unrelated) and `.claude/worktrees/`.
   - Stage explicit paths; never `git add .` / `-A`. Conventional commit message, no Claude attribution.
2. **Push** to `origin` (`pov-it/Trio`) on the current branch. Never force-push.
3. **Build**: `gh workflow run "4. Build Trio" --repo pov-it/Trio --ref <branch>`.
   Capture the run id from `gh run list --workflow="4. Build Trio" --repo pov-it/Trio
   --branch <branch> --limit 1 --json databaseId,status,headSha` (match headSha to `git rev-parse HEAD`).
4. **Monitor until done** — this is mandatory, not optional. Watch with
   `gh run watch <id> --repo pov-it/Trio --exit-status` (use `run_in_background`). Do not
   declare success on dispatch alone.
5. **On failure**: pull failing logs (`gh run view <id> --repo pov-it/Trio --log-failed`),
   find the root cause (usually a Swift compile error), fix in source, re-commit, re-push,
   re-trigger. Repeat up to ~5 attempts. Bail to the user if the failure is CI infra
   (certs/secrets/runner) rather than code, or the same error recurs after 2 fix attempts.

There is a `/ship-ai-insights` slash command with the full procedure; it defaults to
`feature/ai-insights`, so confirm the target branch first when the user is on another.

## Branches & build collisions

- Two long-lived experiment branches: `feature/ai-insights` (lean) and
  `feature/ai-insights+oref-swift` (oref-swift merged in).
- They share `APP_DEV_VERSION 0.8.0` → **never run both builds in parallel** (they collide
  on the TestFlight upload step). If both need building, run `+oref-swift` first; if it's
  green the lean branch almost certainly is too.

## Environment notes

- Host is **Windows / PowerShell**. There is **no local `xcodebuild` or `swift` CLI** — the
  GitHub Actions "4. Build Trio" run is the only place Swift actually compiles. Validate
  Swift changes there, not locally.
- iOS deployment target is **17.0**; use the zero-parameter `.onChange(of:) { ... }` form
  (matches the rest of the codebase).
- Remotes: `origin` = `pov-it/Trio` (our fork, where builds run), `upstream` = `nightscout/Trio`.
