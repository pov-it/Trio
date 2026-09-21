# Extra features vs stock Trio v1.0.1

This branch is based on **nightscout/Trio tag `v1.0.1`** (released 2026-09-20). Everything below is **in addition to** that release. Looping, pumps, CGM drivers, and the iOS 26 Home glass chrome stay on the v1.0.1 side unless a note says otherwise.

No glucose series, Nightscout tokens, or secrets belong in these docs or on the companion path. This is not a TestFlight or device-build report.

## AI Hub / FoodFinder

Entry points:

- Home meal-row **sparkles** pill → AI Hub
- Treatments toolbar fork → FoodFinder (bolus handoff)
- Settings → AI Insights
- Lock-screen / home-screen shortcut widgets (`Trio://foodfinder`, `Trio://caffeine`)

Hub surfaces: AI Chat, Therapy Insights, Recap, FoodFinder, Caffeine tracker, Alcohol tracker, AI Settings.

**Models**

- Default Google Gemini model is **`gemini-flash-latest`** (not a dated snapshot id).
- Also supported: OpenAI, Anthropic, TillyAI (`https://chat.pov-it.tech/v1/chat/completions`), Custom endpoint.
- API keys live in Keychain. Do not commit them.

**FoodFinder**

- Camera / Library / Barcode / Dictate composer (purple accents preserved).
- Composer flushes to the keyboard (no gap); expanded card does not leave a white panel when dragged down.
- Barcode scanner **dismisses after a successful scan**.
- Scanned packaged-food data is attached to the draft and included in the LLM context.
- Albert Heijn lookup + nutrition basis (UoM) / portion scaling from the FoodFinder workstream.
- Meal gallery (see below).

## Night / critical glucose alerts

Intent matches pov-it PR #5 (must not regress):

- Trio **owns** Low / Urgent Low, including with LibreTransmitter in-process. Libre is not treated as a companion alert owner.
- `com.apple.developer.usernotifications.critical-alerts` is present in `Trio.entitlements` (same key as older pov-it `main`). That is **not** a claim that Apple has approved the capability for a given team / profile.
- Default + one-time migration: Trio owns glucose alarms (`forceTrioAlertsWhenCGMProvidesOwn = true`).
- Persisted Low / Urgent Low get Silence & Focus override back on (one-time).
- Critical UN sound is system `.defaultCritical` (not volume 0 during snooze). `playsSound: false` stays silent.
- Critical in-process / AlarmKit fallback still plays through a mute window.
- Foreground notifications present banner + sound.
- Permission request includes `.criticalAlert`.
- **Use CGM App Alerts** may still defer High / forecasted-low only.

Stock v1.0.1 already has the upstream alert rewrite (TrioAlertManager, AlarmKit). This branch keeps that v1.0.1 stack and layers the PR #5 hypo-wake policy on top.

## Meal gallery / groups / bolus reuse

Local-first (`Application Support/MealGallery`):

- Filters: name (title + ingredients), date range, min/max carbs, tags, meal slot.
- Groups: manual tags plus auto folders from the **local hour** of `date` (`Calendar.current`):
  - breakfast 05:00–10:59
  - lunch 11:00–15:59
  - dinner 16:00–21:59
  - other 22:00–04:59
- **Use in Bolus Calculator** and **Open in FoodFinder** from gallery detail.

## Meals Companion share (opt-in)

Off by default (`ai_meal_companion_share_enabled`). Not part of exported `TrioSettings`.

When on, newly archived meals publish a **meal-only** payload. Never glucose, IOB, COB, Nightscout URL/token, pump/insulin, or the Trio therapy App Group.

CloudKit contract (must match [pov-it/meals-companion](https://github.com/pov-it/meals-companion)):

| Item | Value |
| --- | --- |
| Container | `iCloud.org.pov-it.<TEAM>.meals` |
| Zone | `MealsZone` |
| Records | `Meal`, `MealFeed` (not `SharedMeal`) |
| Meal fields | `title`, `photographedAt`, `photo`, `ownerDisplayName` |

Details: [MealCompanionShare.md](MealCompanionShare.md).

## iOS 26 / Liquid Glass (AI Hub only)

v1.0.1 already uses Liquid Glass on Home (`GlassChrome`, `glassActionSheet`). This branch reuses those helpers on **custom AI Hub SwiftUI** only:

- Hub home cards (`.glassPanel`)
- FoodFinder composer Camera / Library / Barcode / Dictate circles (`.glassMaterialFill`)
- iOS 26 system nav/toolbar glass on Hub / FoodFinder / AI Settings (not restyled as custom chrome)

**Not** applied to freeaps / glucose critical-path screens beyond what v1.0.1 already ships. FoodFinder keyboard-flush and “no white leftover panel on drag” are preserved: the composer still uses `.safeAreaInset` and only ignores the **container** home-indicator inset, never `.keyboard`.

## Out of scope / still on Marijn

- Apple Critical Alerts capability on the App ID + provisioning profiles (plist key alone is not enough).
- Adding the meals CloudKit container to the **Trio** App ID (second container; do not put glucose in it).
- Deploying the `Meal` / `MealFeed` schema to CloudKit Production.
- Device / TestFlight verification of alerts, FoodFinder, or companion pairing.
- Whether forecasted-low should stay deferred when “Use CGM App Alerts” is on (current: PR #5 yes).
