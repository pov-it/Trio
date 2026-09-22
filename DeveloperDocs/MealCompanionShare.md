# Meal companion share

Trio can optionally publish a **meal-only** record when FoodFinder archives a meal so [Meals Companion](https://github.com/pov-it/meals-companion) can show the photo, name, and time. That **app** is a separate public repo; Trio only implements the publisher + this contract.

AI Hub / FoodFinder themselves stay **in Trio** (`Trio/Sources/Modules/AIInsights/`). They are not split out as a DanaKit/LibreTransmitter-style submodule or Swift package. See [AIHubAndCompanion.md](AIHubAndCompanion.md).

This is **off by default**. Nothing is written until **Share meals with companion** is enabled in AI Settings or the meal gallery.

Linux / this cloud agent cannot run Xcode, CloudKit, or a device. No TestFlight or pairing success is claimed here.

TestFlight / App Store builds typically **do not contain** `embedded.mobileprovision`. Preflight must read the **code signature** entitlements (`SecCodeCopySelf` / `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`). An absent provision file is unknown, not “not entitled”. Trio only shows “not entitled” when signed entitlements are readable and lack `iCloud.org.pov-it.<TEAMID>.meals`. If the signature cannot be read, it shows that it couldn’t confirm entitlements and still never calls `CKContainer(identifier:)` (that SIGTRAPs). Trio never invents a share URL.

## What is shared

Local outbox JSON (`SharedMealPayload`) is an explicit allow-list:

| Field | Notes |
| --- | --- |
| `schemaVersion` | Currently `1` |
| `id` | FoodFinder meal UUID |
| `date` | Meal timestamp |
| `mealName` | Optional |
| `thumbnailFilename` | Optional; JPEG bytes stored beside the JSON in the outbox |
| `carbs` | Optional grams **in the local outbox only** |

CloudKit `Meal` records (what the companion actually reads) use a **stricter** field set and **do not** include carbs:

| Field | Type |
| --- | --- |
| `title` | String |
| `photographedAt` | Date |
| `photo` | CKAsset (JPEG) |
| `ownerDisplayName` | String |

`MealFeed` (one root record, shared):

| Field | Type |
| --- | --- |
| `ownerDisplayName` | String |

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

## CloudKit contract (meals-companion)

Preferred production path: **private CloudKit database + `CKShare`**.

Container (derived from Trio’s signing team, same pattern as the companion app):

```
iCloud.org.pov-it.<TEAMID>.meals
```

Example for team `Q6QCL8J6FN`: `iCloud.org.pov-it.Q6QCL8J6FN.meals`.

Do **not** reuse Trio’s glucose/therapy iCloud container. Do not put glucose, IOB, COB, insulin, or Nightscout fields on these records. The companion ignores those keys even if a publisher writes them; still do not write them.

Zone: `MealsZone`

Record types: **`Meal`** and **`MealFeed`**. The older `SharedMeal` name is not used.

Override the container without baking a Team ID into git (only if the derived identifier is wrong):

```
UserDefaults key: ai_meal_companion_cloudkit_container
Value:            iCloud.org.pov-it.<TEAMID>.meals
```

Trio will:

1. Create/save `MealsZone` in the **private** DB.
2. Upsert root `MealFeed` (`MealFeedRoot`) with `ownerDisplayName`.
3. Save each opted-in meal as a `Meal` (title, photographedAt, photo, ownerDisplayName).
4. Create a `CKShare` on that root when a share URL is not stored yet (`ai_meal_companion_share_url`), saving the root record and share together. Persists `share.url` only when it is an `https` iCloud share link.

**Companion invite:** Companion sharing settings show the resolved container (`iCloud.org.pov-it.Q6QCL8J6FN.meals` for this team — never a `<TEAM>` placeholder), the share URL when it exists, **Copy invite link**, and **Create / refresh invite** (calls `ensureInviteShare` without publishing glucose). Copy writes the CloudKit `https://…icloud.com/share/…` URL to the pasteboard (no `ShareLink` in that Form — that combination crashed on TestFlight). Send the copied iCloud share URL to the invitee; pairing happens in meals-companion.

Trio never invents or hardcodes an invite URL. `CKShare` is saved **with** the `MealFeed` root in one `CKModifyRecordsOperation`; only a validated `share.url` is stored in `ai_meal_companion_share_url`.

If no team id is available (`TEAMID` / empty / `$(DEVELOPMENT_TEAM)` still unsubstituted), the publisher falls back to team `Q6QCL8J6FN` for this fork so the container id is still real.

Apple-side work that git cannot do:

1. Add this meals container as a **second** CloudKit container on the Trio App ID (keep glucose elsewhere).
2. CloudKit Dashboard: record types `Meal` and `MealFeed` with the fields above; mark `Meal` queryable; **Deploy Schema to Production** before TestFlight. TestFlight uses Production; “Cannot create new type MealFeed in production schema” means this deploy has not happened. Trio does not write Development-only types into Production.
3. After the App ID has the container, regenerate Match profiles once: run **3. Create Certificates** with `MATCH_FORCE=true` (workflow input or repo variable). That does **not** nuke certificates (`FORCE_NUKE_CERTS` stays off). Then unset `MATCH_FORCE`.
4. Invite the companion Apple ID (Messages / iCloud share URL). Pairing happens in meals-companion, not in Trio.

## Dedicated companion App Group (optional, same phone only)

If a sibling process on the **same** phone needs the JSON, register a **new** App Group, for example `group.org.pov-it.<TEAMID>.meals`. Do **not** add meal JSON to the Trio therapy App Group. The publisher refuses any suite name containing `trio-app-group`.

```
UserDefaults key: ai_meal_companion_app_group
```

This PR does not add that App Group to `Trio.entitlements`.

## Settings

- **AI Settings → Companion sharing → Share meals with companion**
- Meal gallery → ••• → Companion sharing

Same `UserDefaults` key: `ai_meal_companion_share_enabled` (bool, default `false`). This is **not** part of exported `TrioSettings`, so a settings backup cannot silently turn sharing on.

Optional display name for `MealFeed` / `Meal.ownerDisplayName`: `ai_meal_companion_owner_display_name`.

## Gallery meal slots

Auto folders use the **local hour** of `date` (`Calendar.current`):

| Slot | Local hours |
| --- | --- |
| Breakfast | 05:00–10:59 |
| Lunch | 11:00–15:59 |
| Dinner | 16:00–21:59 |
| Other | 22:00–04:59 |

Manual groups/tags stay on the gallery index. They are not CloudKit fields.
