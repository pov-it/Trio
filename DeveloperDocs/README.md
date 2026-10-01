# Developer docs (pov-it extras on `1.0.1-ai-hub-companion`)

Stock Trio docs and the oref-swift notes live alongside this folder. Everything listed here is **in addition to** nightscout/Trio tag `v1.0.1`.

## In-repo vs extracted kits

| Feature | Where it lives | Shipping model |
| --- | --- | --- |
| Dana pump / LibreLink-family CGM | `DanaKit/`, `LibreTransmitter/` | Git submodules (separate GitHub repos) |
| **AI Hub / FoodFinder / meal gallery** | `Trio/Sources/Modules/AIInsights/` | **In-repo Trio module** — same commit as the app |
| AutoPresets | `Trio/Sources/Modules/AutoPresets/` | In-repo sibling folder |
| Meals Companion **app** | [pov-it/meals-companion](https://github.com/pov-it/meals-companion) | Separate iPhone app (meal photos only) |

Marijn confirmed 2026-09-21: **do not** split AI Hub into a GitHub/SPM module the way Dana and LibreLink are split. Keep the folder + these docs. The companion app is a different product; it is not AI Hub extracted from Trio.

Module map: [`Trio/Sources/Modules/AIInsights/README.md`](../Trio/Sources/Modules/AIInsights/README.md).

## Docs in this folder

- [AIHubAndCompanion.md](AIHubAndCompanion.md) — extras vs stock v1.0.1 (Hub, FoodFinder, night alerts, gallery, liquid glass)
- [MealCompanionShare.md](MealCompanionShare.md) — meal-only CloudKit contract (`Meal` / `MealFeed`, no glucose)
- [FoodFinderAgentLab/](FoodFinderAgentLab/) — local eval harness for FoodFinder prompts
- [OrefSwift/](OrefSwift/) — upstream oref-swift port notes (already in v1.0.1)

No medical advice. These extras are not claimed as TestFlight-verified.
