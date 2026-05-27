# FoodFinder Agent Lab

Local browser playground for the FoodFinder lookup agent. It lets you test the
pipeline without rebuilding the iOS app:

1. Parse a meal description or photos into ingredient intents with an AI provider.
2. Run nutrition lookups against OpenFoodFacts and, optionally, USDA FoodData Central.
3. Show selected sources, alternate matches, confidence, and the final JSON payload.

## Run

```powershell
node DeveloperDocs\FoodFinderAgentLab\server.mjs
```

Then open:

```text
http://localhost:8787
```

API keys are sent only to the local server process for the request. The browser
stores them in `localStorage` for convenience while testing on this machine.

