# AI Hub (in-repo Trio module)

AI Hub, FoodFinder, meal gallery, chat, recap, and caffeine/alcohol trackers live **inside this Trio tree**. They are not a separate GitHub repository, Swift package, or git submodule.

DanaKit and LibreTransmitter (LibreLink-family) are **external** git submodules under the repo root (`DanaKit/`, `LibreTransmitter/`). Do **not** split AI Hub the same way. Marijn confirmed (2026-09-21): keep it in Trio for now.

Feature list vs stock Trio v1.0.1: [`DeveloperDocs/AIHubAndCompanion.md`](../../../../DeveloperDocs/AIHubAndCompanion.md).

Meal-only companion **publisher** (this module) vs the separate companion **app**: [`DeveloperDocs/MealCompanionShare.md`](../../../../DeveloperDocs/MealCompanionShare.md) and [pov-it/meals-companion](https://github.com/pov-it/meals-companion). The companion app is a different product; it is not “AI Hub extracted from Trio.”

## Layout

```
Trio/Sources/Modules/AIInsights/
  README.md                          this file
  AIInsightsDataFlow.swift           namespace, providers, models, default Gemini Flash latest
  AIInsightsProvider.swift           data access for chat / insights
  AIInsightsStateModel.swift
  AIInsightsChatStateModel.swift
  AIInsightsFoodFinderStateModel.swift
  AIInsightsTherapyInsightsStateModel.swift
  ZGlucoParser.swift
  Services/                          LLM adapter, gallery, companion share, recap, trackers
  View/                              Hub, FoodFinder, gallery, chat, settings, camera/barcode
```

Sibling in-repo folder (also not a package): `Trio/Sources/Modules/AutoPresets/` — activity-based override presets, wired from Settings and `AppDelegate`.

Xcode: files are in the Trio app target (`Trio.xcodeproj`), grouped as **AIInsights** / **AutoPresets**. Paths are `SOURCE_ROOT` so they compile from `Trio/Sources/Modules/...`.

## Integration points (outside this folder)

These stay in Trio so Hub is a feature, not a plug-in:

| Location | Role |
| --- | --- |
| `Router/Screen.swift` | `.aiInsights`, `.aiFoodFinder`, `.aiChat`, `.aiSettings`, `.aiCaffeine`, `.autoPresets` |
| `Home/View/HomeRootView+MealPanel.swift` | sparkles pill → Hub |
| `Treatments/` | FoodFinder sheet + bolus handoff |
| `Settings/SettingItems.swift` | AI Insights search/settings row |
| `Models/TrioSettings.swift` | provider/model/FoodFinder fields (not companion opt-in) |
| `LiveActivity/Views/FoodShortcutWidgets.swift` | lock-screen shortcuts (`Trio://foodfinder`, `Trio://caffeine`) |
| `TrioApp.swift` / `AppDelegate.swift` | URL routing, monthly recap catch-up, AutoPresets start |

Glucose alerts / critical-alert policy is **not** in this folder; it lives under `Trio/Sources/Services/Alerts/` and must not regress vs PR #5.

## Boundaries

- **In this folder:** UI + FoodFinder/LLM + local meal gallery + opt-in meal-only CloudKit publisher.
- **Not in this folder:** oref/looping, pump/CGM drivers, glucose time series UI, Nightscout tokens.
- **Never on the companion path:** glucose, IOB, COB, Nightscout URL/token, pump fields, Trio therapy App Group.
