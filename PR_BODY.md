## ⚠️ MEDICAL REVIEW REQUIRED — do NOT run on pump before TestFlight alert testing

Automated sync of **381 upstream commits** from `nightscout:dev` into `feature/ai-insights+oref-swift`.
Merged on Linux by the Hermes agent — **NOT built or tested locally** (Trio needs Xcode/macOS). Only pre-merge signal is the GitHub Actions build (compiles != alerts work).

### 🔴 Highest-risk change — alert architecture rewrite
Upstream replaced the whole notification stack with `TrioAlertManager`. Two conflicting alert files resolved by **taking upstream wholesale**:
- `APS/DeviceDataManager.swift` -> upstream
- `Services/UserNotifications/UserNotificationsManager.swift` -> upstream

**Feature dropped:** custom `shouldSuppressPumpTimeOffsetAlert` suppression is **gone** (0 refs left, clean drop). Reimplement on top of `TrioAlertManager` if still needed.

### 🟢 Your features preserved (kept both sides)
- `Models/TrioSettings.swift` — AI/oref settings kept + upstream fields
- `Router/Screen.swift` — AI screens kept + upstream treatmentsSettings
- `Trio.xcodeproj/project.pbxproj` — ours (AI/AutoPresets; no upstream conflict)
- `Localizations/Main/Localizable.xcstrings` — JSON union 2555+380=2935, re-parse verified

### ✅ TestFlight checklist before trusting on pump
- [ ] Low-glucose alert fires + critical sound
- [ ] High-glucose alert fires
- [ ] Snooze silences (new applySnooze path)
- [ ] Pump fault/error notification fires
- [ ] Carbs-required notification
- [ ] No duplicate/missing/stuck alerts after cold start
- [ ] Decide whether pump-time-offset suppression must be re-added

Full detail: see MERGE-REVIEW.md in this branch.
