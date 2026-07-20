# ⚠️ MEDICAL REVIEW REQUIRED — Merge sync: `feature/ai-insights+oref-swift` ← `nightscout:dev`

**Date:** 2026-07-20
**Merged by:** Hermes agent (automated), on Linux — **NOT built or tested locally** (Trio requires Xcode/macOS).
**Only signal available:** the GitHub Actions build workflow. A green build proves the code *compiles*, **not** that alerting still works.

---

## 🔴 What YOU must test in TestFlight before running this on your pump

Upstream `nightscout/dev` **rewrote the entire alert/notification architecture** (introduced `TrioAlertManager`, deleted ~536 lines of the old glucose/pump notification machinery). Per your instruction, the two conflicting alert files were resolved by **taking the upstream version wholesale**:

- `Trio/Sources/APS/DeviceDataManager.swift` → **upstream version** (`trioAlertManager.issueAlert(alert)` replaces the old `alertHistoryStorage.addAlert(...)` + manual `ackAlert` path)
- `Trio/Sources/Services/UserNotifications/UserNotificationsManager.swift` → **upstream version** (old manual glucose-token / snooze-date / `sendGlucoseNotification` logic replaced by the new `TrioAlertManager` + `applySnooze` flow)

### ⚠️ FEATURE DROPPED IN THIS MERGE
Your custom **`shouldSuppressPumpTimeOffsetAlert`** suppression (stale pump-time-offset alerts) existed **only** in those two files and is **GONE** after taking upstream. It has 0 references left in the tree (clean drop, no build break) — but the behaviour is no longer present. If you still need it, it must be **reimplemented on top of `TrioAlertManager`**.

### Test checklist on device (TestFlight):
- [ ] **Low-glucose alert** fires + sounds (critical sound)
- [ ] **High-glucose alert** fires
- [ ] **Snooze** works and actually silences (new `applySnooze` path)
- [ ] **Pump fault/error notification** fires and routes to pump config
- [ ] **Carbs-required** notification
- [ ] No duplicate / missing / stuck alerts after cold start
- [ ] (If needed) decide whether pump-time-offset suppression must be re-added

---

## 🟢 Low-risk conflicts (kept both sides — your features preserved)
- `Trio/Sources/Models/TrioSettings.swift` — your AI/oref settings **kept** + upstream fields
- `Trio/Sources/Router/Screen.swift` — your AI screens **kept** + upstream `treatmentsSettings`
- `Trio.xcodeproj/project.pbxproj` — kept **ours** (your AI/AutoPresets file entries; upstream had no competing entries)
- `Trio/Sources/Localizations/Main/Localizable.xcstrings` — **JSON union**: upstream base (2555 strings) + your 380 AI-feature strings = 2935 total. Valid JSON, verified re-parse.

## Static checks done (Linux, no build)
- No leftover conflict markers anywhere.
- Dropped-feature symbols (`shouldSuppressPumpTimeOffsetAlert`, `ackAlert`, `sendGlucoseNotification`, `lastGlucoseAlertToken`, `alertToken`) → **0 dangling references**.
- Still-defined symbols (`AlertHistoryStorage` protocol, `BaseAlertHistoryStorage`, `StorageAssembly` registration, `snoozeUntilDate`) → intact and used by `TrioAlertManager`.

**Bottom line:** treat this as an UNVERIFIED build. Test the alert paths above in TestFlight before trusting it on your pump.
