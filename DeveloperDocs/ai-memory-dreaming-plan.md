# Plan: strengthen Trio AI-chat memory ("dreaming"-inspired)

## Inspiration — OpenAI "dreaming" (Apr 2026)

Key principles from OpenAI's memory "dreaming" rollout:
- **Background consolidation**: a process that runs *outside* the live turn, reads across *many* past conversations, and synthesizes/curates a memory state — no explicit "remember this" needed.
- **Narrative, categorized profile**: a coherent prose dossier split into categories (work, hobbies, travel…) instead of a flat bullet list.
- **Temporal freshness / self-revision**: memories are updated as time passes — "going to Singapore in July" → "went to Singapore in July 2026" once the trip ends; stale, time-bound facts decay.
- **User control**: a reviewable memory summary page; the user can correct, delete, or say "don't mention this," and steer what gets surfaced and when.
- **Decoupled from answering**: consolidation is a separate compute step, not piggy-backed on the chat response. Reported large gains in fact recall (41→83%), preference use (31→71%), and freshness (52→75%).

Sources: [OpenAI: Dreaming](https://openai.com/index/chatgpt-memory-dreaming/) · [the-decoder](https://the-decoder.com/chatgpt-now-saves-narrative-dossiers-about-you-sorted-by-work-hobbies-and-travel-preferences/)

## Where we are today

Files: `Trio/Sources/Modules/AIInsights/AIInsightsChatStateModel.swift`, `Services/AIInsights_PeriodicRecap.swift`.

- **Knowledge Base**: one `knowledgeBase: String` (UserDefaults `ai_insights_knowledge_base`), capped at ~10 bullets. The model is told to **rewrite the ENTIRE KB inline** at the end of *every* chat answer inside `<KNOWLEDGE>…</KNOWLEDGE>`; the app overwrites the stored string wholesale (line ~470). Injected into the system prompt as "USER PROFILE & KNOWLEDGE BASE" (line ~865).
- **History**: only the last 10 messages are sent; older ones are *dropped* with a placeholder note (line ~427) — real context loss, no summary.
- **PeriodicRecap**: background-scheduled (weekly/monthly) *observation* recaps from 30 days of chat titles + applied suggestions + trackers. Stored & shown to the user, but **never fed back** into the chat's memory.

### Gaps vs dreaming
1. Memory write is **synchronous with the answer** — costs output tokens/latency every turn, competes with answer quality, and only reacts to the *current* turn (no cross-conversation synthesis).
2. Memory is a **flat 10-bullet list** — no categories, no narrative, no salience, hard cap loses detail.
3. **No temporal model** — no timestamps, no "planned→happened" revision, no decay of stale facts.
4. Old conversations are **discarded**, not consolidated.
5. **No user-facing review/edit** of what the AI remembers.
6. Brittle regex `<KNOWLEDGE>` extraction; malformed tags leak or wipe memory.

## Plan

Reuse what we have: `PeriodicRecapService` scheduling/storage pattern, `AIServiceAdapter`, UserDefaults persistence, the existing tracker/meal/recap context builders.

### Phase 1 — Structured, categorized memory store (foundation)
- New `AIInsights_UserMemory` service (mirror `PeriodicRecapService` singleton + UserDefaults).
- Model:
  ```
  struct MemoryFact: Codable {
      id, category, text,
      createdAt, lastConfirmedAt,
      salience: Double,          // 0–1, decays over time
      status: .active/.archived,
      timeBound: Bool, expiresAt: Date?   // for "planned" events
      userEdited: Bool           // protect manual edits from auto-overwrite
  }
  enum MemoryCategory { diabetesProfile, lifestyleDiet, routineActivity, preferences, goalsContext }
  ```
- Render to a **narrative, per-category** block for the prompt (replaces the flat bullet injection at line ~865).
- One-time migration: parse the existing flat `knowledgeBase` into `lifestyleDiet` facts.

### Phase 2 — Decouple capture from answering (cheap extraction)
- Stop making the chat model rewrite the whole KB inline. Instead, after a chat exchange, run a **small, cheap async extraction** call (low max-tokens, `disableThinking` on Gemini) that returns only *candidate* new/changed facts as JSON (category + text + timeBound). Merge into the store off the critical path.
- Keep the live answer focused on answering; remove the `<KNOWLEDGE>` rewrite instruction from the main prompt (lines ~916-928).

### Phase 3 — "Dreaming" consolidation pass (the core)
- Add a background `consolidateMemory()` to `AIInsights_UserMemory`, scheduled like recaps (reuse the weekly/monthly cadence infra; also trigger opportunistically when the app backgrounds and on a debounce after N new candidate facts).
- It feeds the model: current categorized memory + recent conversation snippets + candidate facts, and asks it to **rewrite the consolidated memory**: merge duplicates, resolve conflicts (prefer newer + `userEdited`), convert planned→past, **decay/archive** stale or low-salience facts, and keep each category tight. This is the cross-conversation synthesis dreaming does — but offline, not per-turn.
- Temporal freshness: on each pass, expire `timeBound` facts past `expiresAt` (rewrite "planning X" → "did X" or archive), and lower `salience` for facts not re-confirmed recently; drop below a floor.

### Phase 4 — History summarization (no more silent drops)
- Replace the "older history omitted" placeholder (line ~427) with a rolling **conversation summary**: when a thread exceeds the window, summarize the dropped turns into a compact recap kept alongside the last-10 messages. Cheap async call; cached per thread.

### Phase 5 — User-facing memory page
- New "What Trio remembers" view (sibling to `AIInsightsRecapView`): shows the categorized narrative profile; per-fact **Edit / Delete / Don't mention again**; a global memory on/off and "pause learning" toggle in AI Settings. Manual edits set `userEdited` so consolidation won't overwrite them. (Matches dreaming's review/correct UX and is good for a health app's trust/privacy.)

### Phase 6 — Retrieval quality
- Inject only the **top-salience + most-recent** facts per category into the prompt (budgeted), rather than everything, so the profile scales without bloating context. Optionally tag facts the current question touches.

## Guardrails (health-app specific)
- All memory stays **on-device** (UserDefaults/file), same as today; never auto-uploaded.
- Consolidation prompt must **never invent** facts or store dosing decisions as "preferences"; observations only, consistent with the existing recap "no advice" stance.
- Keep it provider-agnostic (works on Gemini/OpenAI/Anthropic via `AIServiceAdapter`); use `disableThinking` + small token budgets to keep background passes cheap.

## Verification
- No local Swift build; validate via `4. Build Trio` CI, then on-device: confirm (a) facts captured without "remember" prompts, (b) categorized narrative shows in the memory page, (c) a planned event flips to past after its date, (d) manual edits survive a consolidation pass, (e) chat latency unchanged (capture is now off the critical path). Use the FoodFinder lab harness pattern to dry-run consolidation prompts against Gemini before wiring the UI.

## Suggested sequencing
Phase 1 + 2 first (foundation + latency win), then 3 (dreaming), then 5 (user trust), then 4 and 6. Each phase is independently shippable and falls back to current behaviour if disabled.

---

# Add-on: connect an external Agent (Hermes / "Agent" / Claude / …) to Trio

Goal (user): let an external agent either **read your diabetes data**, or **be the assistant you talk to inside Trio**, with the data pulled live from Trio.

## Two directions
- **Outbound** — Trio *exposes* read-only diabetes data so an external agent can consume it.
- **Inbound** — an external agent *becomes the brain* of the in-app chat (bring-your-own-agent), pulling Trio data as it reasons.

## One tool surface, three transports
Define a single **read-only Diabetes Data Tool set** once and expose it through whichever transport an agent speaks. Reuses the function-calling we just built in `AIServiceAdapter` and the existing `Shortcuts/` intents.

Tools (read-only):
`get_current_status` (glucose, trend, IOB, COB), `get_glucose_history(range)`, `get_settings` (basal/ISF/CR/target), `get_active_treatments`, `get_meals` (FoodFinder), `get_trackers` (caffeine/alcohol/autopresets), `get_memory_profile` (the dreaming dossier from the plan above). Writes (bolus/carbs/override) stay OUT of the default surface — see consent.

### Transport A — App Intents / Shortcuts (on-device iOS agents)  ← cheapest, native
Trio already ships read/act intents (`Shortcuts/State/ListStateIntent`, `Bolus`, `Carbs`, `Override`, `TempPresets`). Extend with rich **read** intents (`GetDiabetesSummaryIntent`, `GetGlucoseTrendIntent`, `GetMemoryProfileIntent`) returning structured values. Any on-device assistant app, Siri, or a Shortcuts automation can then query Trio without a server — sandbox-friendly. Best fit for an on-device "Agent".

### Transport B — MCP server bridge (desktop/cloud agents: Claude, Hermes)
External agents that speak **MCP** connect to a small **companion MCP server** that wraps the user's **Nightscout** API (which Trio already populates) and exposes the tool set above as MCP tools/resources. No new cloud — data stays in the user's own Nightscout. Ship it as a self-hostable script (mirror the `DeveloperDocs/FoodFinderAgentLab` Node pattern) + setup doc. This is how Hermes/Claude-style agents read structured data today.

### Transport C — Bring-your-own-agent in the Trio chat (inbound)
The chat already supports a `custom` provider + baseURL (`AIInsightsChatStateModel`). Point it at a Hermes/agent endpoint to make that agent the chat brain. Upgrade from today's "stuff context into the prompt" to **agentic tool access**: hand the external agent the Diabetes Data Tools so it pulls exactly what it needs on demand (same loop pattern as FoodFinder). Works for any function-calling-capable endpoint.

## Consent & privacy (non-negotiable for health data)
- **Read-only by default.** Any write/act tool (bolus, carbs, override) is opt-in, per-action, and still routes through Trio's existing on-device confirmation — never autonomous dosing.
- **Per-connection scoped tokens**, revocable; a **"Connected Agents"** settings page listing each agent, its scopes, and last-access time, with a kill switch.
- **On-device first**; MCP path reuses the user's own Nightscout (no new servers holding PHI).
- **Access audit log** the user can review.
- Prominent disclaimer: connected agents are not medical devices.

## Ties into the memory plan
`get_memory_profile` exposes the consolidated "dreaming" dossier, so an external agent inherits rich, current context (preferences, routine, goals) instead of raw numbers only — making Hermes/Claude immediately useful without re-learning the user.

## Phasing
1. **Read-only App Intents** expansion + define the shared Diabetes Data Tool set (also used in-chat). On-device, no server.
2. **Inbound BYO-agent**: custom endpoint as chat brain + agentic tool access.
3. **MCP bridge** (Nightscout-wrapping companion) + **Connected Agents** consent UI + audit log.

## Verification
Dry-run each transport before UI: call the App Intents from Shortcuts; exercise the MCP bridge with an MCP client against a test Nightscout; point the chat `custom` provider at a local mock agent and confirm it can call the data tools. Then CI build + on-device check that reads are scoped, logged, and revocable.

---

# Concrete implementation plan — Transport A (App Intents / Shortcuts)

Chosen first transport: **App Intents**. It is native, on-device, sandbox-safe, needs no server, and Trio already ships the scaffolding — `StateResults` AppEntity (glucose/trend/delta/IOB/COB/unit), `ListStateIntent`, `StateBGQuery`, and `AppShortcuts.swift`. We extend that surface into a read-only "agent data" set that any on-device assistant, Siri, or a Shortcuts automation can call, and that the in-app chat reuses as its tool layer.

## What exists (reuse, don't rebuild)
- `Trio/Sources/Shortcuts/State/StateIntentRequest.swift` — `StateResults: AppEntity` + the data fetch.
- `Trio/Sources/Shortcuts/State/ListStateIntent.swift` — an `AppIntent` returning state.
- `Trio/Sources/Shortcuts/AppShortcuts.swift` — `AppShortcutsProvider` registration.
- `AIInsights_DataAggregator` (already aggregates glucose/settings/TIR) and the new `AIInsights.UserMemoryStore` (memory dossier).

## New intents (read-only)
Add under `Trio/Sources/Shortcuts/AgentData/` (the LiveActivity `Views` folder is synchronized, but the main target is not — so add each new file to `project.pbxproj` exactly like the existing Shortcuts files, or extend the existing `State` files to avoid pbxproj edits):

1. `GetDiabetesSummaryIntent` → returns a `DiabetesSummary` AppEntity: current glucose+trend+delta, IOB, COB, average glucose / TIR / GMI over a `periodDays` parameter, and current basal/ISF/CR/target. Built from `DataAggregator` (same source the chat uses).
2. `GetGlucoseTrendIntent(range)` → array of recent readings (value, time) for a requested window — for agents that want the curve.
3. `GetMemoryProfileIntent` → the categorized narrative from `UserMemoryStore.shared.narrativeForPrompt()` as a string property, so an agent inherits the "dreaming" dossier.
4. (optional) `GetActiveTreatmentsIntent` → recent carbs/boluses/overrides summary.

Each is a plain `AppIntent` with `static var openAppWhenRun = false` and a `@MainActor func perform() async throws -> some IntentResult & ReturnsValue<…>` that reads through a provider/resolver the same way `StateIntentRequest` does. Register them in `AppShortcuts.swift`.

## Shared tool layer (one definition, reused by the chat)
Factor the read logic into an `AgentDataProvider` (plain struct/service, not an intent) with methods `currentStatus()`, `summary(periodDays:)`, `glucoseTrend(range:)`, `memoryProfile()`, `activeTreatments()`. The App Intents become thin wrappers, and the **in-app chat's future agentic tools (Transport C) call the exact same `AgentDataProvider`** — so the agent's data access and the Shortcuts data access can never drift.

## Consent & safety
- All new intents are **read-only**; no bolus/carb writing is added here (those already exist separately and keep their own confirmation flow).
- Add an AI-Settings toggle `aiAgentDataSharingEnabled` (default OFF). Each intent's `perform()` guards on it and throws a clear "enable Agent Data Sharing in Trio → AI Settings" error when off — so data is never exposed until the user opts in.
- Append a line to an on-device **access log** (UserDefaults ring buffer) on each successful read: timestamp + intent name. Surface it on a "Connected Agents / Access log" settings row (shared with later transports).
- Keep payloads scoped: summaries and trends, not raw exports; no Nightscout tokens or identifiers in the returned entities.

## Steps
1. `AgentDataProvider` + `DiabetesSummary`/`GlucoseReading` AppEntities (mirror `StateResults`).
2. The 3–4 intents wrapping `AgentDataProvider`, gated by `aiAgentDataSharingEnabled`, with access-log writes.
3. Register in `AppShortcuts.swift`; add the settings toggle + access-log row.
4. pbxproj: add the new files like the existing `Shortcuts/State/*` entries (PBXBuildFile, PBXFileReference, group children, Sources phase) — or, to avoid pbxproj risk on CI-only builds, start by adding the new intents *inside* the existing `Shortcuts/State` files.

## Verification
- Build on CI ("4. Build Trio").
- On device: create a Shortcut that calls `GetDiabetesSummaryIntent` and confirm it returns live values; flip the toggle off and confirm it refuses; check the access log records the call. Then have an on-device assistant invoke the same Shortcut.
- Confirm the chat (when Transport C lands) and Shortcuts read identical numbers via the shared `AgentDataProvider`.

This delivers the user's "let an Agent read your data / talk to you with your Trio data" via the lowest-risk, fully on-device path first; Transports B (MCP/Nightscout) and C (BYO-agent chat brain) layer on top reusing the same `AgentDataProvider` and consent model.
