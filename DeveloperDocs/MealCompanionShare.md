# Meal companion share (Mayee)

Trio can optionally publish a **meal-only** record when FoodFinder archives a meal, so a companion app (Mayee) can show the same photo / name / time without receiving therapy data.

This is **off by default**. Nothing is written until the user enables **Share meals with companion** in AI Settings or the meal gallery.

Linux / this cloud agent cannot run Xcode, CloudKit, or a device. The Trio-side publisher, outbox, privacy checks, and settings exist in source; live CloudKit sharing still needs Marijn’s Apple Team.

## What is shared

`SharedMealPayload` is an explicit allow-list:

| Field | Notes |
| --- | --- |
| `schemaVersion` | Currently `1` |
| `id` | FoodFinder meal UUID |
| `date` | Meal timestamp |
| `mealName` | Optional |
| `thumbnailFilename` | Optional; JPEG bytes stored beside the JSON in the outbox |
| `carbs` | Optional grams |

## What is never shared

The publisher refuses to write a payload whose JSON object keys include any of:

- glucose / sgv / bg
- iob / cob / insulin
- nightscout URL or token
- api keys / secrets
- pump / forecast fields

The Trio therapy App Group (`$(APP_GROUP_ID)` / `trio-app-group`) is **not** used. Nightscout credentials that already live there are never copied into a meal payload or into a companion suite.

Enabling the toggle does **not** backfill history. Only meals archived (or manually shared from gallery detail) after opt-in are published.

## Local outbox (works without CloudKit)

When sharing is on, Trio writes:

```
Application Support/SharedMealsOutbox/<uuid>.json
Application Support/SharedMealsOutbox/<uuid>.jpg   # if a thumbnail exists
```

This is offline-first. Gallery archive does not wait on network. Thumbnails in `Application Support/MealGallery/` stay on the phone regardless of sharing.

## CloudKit (not configured in this PR)

Preferred production path: **private CloudKit database + `CKShare` to Mayee**.

That requires, on the Apple Developer team that signs Trio:

1. iCloud capability with CloudKit on the Trio App ID.
2. A container, for example `iCloud.org.nightscout.<TEAMID>.trio.meals` — replace `TEAMID`; do not reuse a Nightscout secrets container.
3. Record type `SharedMeal` in the CloudKit Dashboard with fields:
   - `schemaVersion` (Int64)
   - `date` (Date/Time)
   - `mealName` (String)
   - `carbs` (Double, optional)
   - `thumbnailFilename` (String, optional)
   - optional `thumbnail` (Asset) once you attach the JPEG as a `CKAsset`
4. Mayee’s App ID must use the **same** container, plus CloudKit.
5. Sharing UI (`UICloudSharingController` / `CKShare`) so Marijn can invite Mayee to a private-DB share. This PR does **not** present that UI; `CloudKitMealShareTransport` only saves to the **private** DB when a container identifier is set.

To point Trio at a container without baking a Team ID into git:

```
UserDefaults key: ai_meal_companion_cloudkit_container
Value:            iCloud.org.nightscout.<TEAMID>.trio.meals
```

If the key is empty (the default), CloudKit is a no-op and the outbox is still the source of truth.

## Dedicated companion App Group (optional, separate from Trio)

If Mayee is another process on the same phone (extension / sibling app), register a **new** App Group, for example:

```
group.org.nightscout.<TEAMID>.trio.companion-meals
```

Do **not** add meal JSON to `group.org.nightscout.<TEAMID>.trio.trio-app-group`. The publisher refuses any suite name containing `trio-app-group`.

Set the companion suite with:

```
UserDefaults key: ai_meal_companion_app_group
```

Then add that App Group to Trio **and** Mayee entitlements. This PR does not change `Trio.entitlements` (still only `$(APP_GROUP_ID)`).

A push notification to Mayee (“new shared meal”) would be a later step: APNs on Mayee’s app, triggered after a successful CloudKit save. Not implemented here; the outbox / private-DB record is the data plane.

## Settings

- **AI Settings → Companion sharing → Share meals with companion**
- Meal gallery → ••• → Companion sharing

Same `UserDefaults` key: `ai_meal_companion_share_enabled` (bool, default `false`). This is **not** part of exported `TrioSettings`, so a settings backup cannot silently turn sharing on.

## Gallery meal slots

Auto folders use the **local hour** of `date` (`Calendar.current`, so Europe/Amsterdam when the phone is on that zone):

| Slot | Local hours |
| --- | --- |
| Breakfast | 05:00–10:59 |
| Lunch | 11:00–15:59 |
| Dinner | 16:00–21:59 |
| Other | 22:00–04:59 |

Manual groups/tags (e.g. “halve stokbroodjes”) are stored on the gallery index and never leave the phone unless companion sharing is on (and even then only the meal-only payload is published, not the tag list).
