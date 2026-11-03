# rsg-beekeeper — Developer Docs

Version 3.2.0. For install and config, see [README.md](README.md).

## Contents
1. Architecture
2. Data flow and hive state
3. Events
4. Database
5. Security model
6. Server owner how-tos
7. Troubleshooting

## 1. Architecture
| File | Purpose |
|---|---|
| `fxmanifest.lua` | Manifest; depends on rsg-core, rsg-inventory, rsg-target, rsg-gizmo, oxmysql |
| `shared/config.lua` | All settings (`Config.AutoDatabase`, `Config.Placement`, `Config.Beehive`, webhooks, prop list) |
| `client/client.lua` | Hive streaming (entities spawn within `renderDistance`), swarm PTFX, stinging, rsg-gizmo placement, rsg-target option, NUI bridge |
| `server/server.lua` | Auto database, useable items, all hive actions, upkeep tick, scheduled full/calm-expiry broadcasts |
| `server/webhook.lua` | Queued, rate-limited Discord logging (`BeekeeperWebhook.Send`) and `/beehivewebhook` |
| `server/versionchecker.lua` | Console version check |
| `html/` | Hive management panel (Roboto, leather & gold theme, no vignette) |
| `install.sql` | Manual schema (same as the auto-build in `server.lua`) |
| `installation/` | `items.lua` entries and item images |
| `locales/*.json` | 10 languages, identical keys |

The script has no exports.

## 2. Data flow and hive state
- **Population** is never stored. It's worked out from `activated_at`: `floor(elapsed / growthIntervalSeconds) * beesPerInterval`, capped at `population.max`.
- **Upkeep** runs every `upkeep.tickIntervalSeconds` as one `UPDATE` over every full, active hive (food/water decay, health regen or decay, honey gain while fed). Hives that reach 0 health are reset to empty (`active = 0`), and the hive stays placed.
- **Calm** is `smoked_until` (unix time). The server schedules a `hiveCalmExpired` broadcast and a `beehiveFull` broadcast, and restores both timers on start.
- Item metadata: the smoker stores remaining uses in `info.uses`; the water bucket stores them in `info[waterUsesKey]`.

## 3. Events
### Client → server (all re-validated)
| Event | Args | Checks |
|---|---|---|
| `rsg-beekeeper:server:placeBeehive` | `coords, heading, prop` | action lock, prop in `Config.BeeHiveProps`, `rsg-gizmo:IsPlacementValid` (finite coords + ped distance), spacing, per-player cap, item removed before insert (refunded on DB failure) |
| `rsg-beekeeper:server:requestBeehives` | — | player loaded, 10s throttle |
| `rsg-beekeeper:server:getHiveInfo` | `id, isRefresh` | player, 1s throttle, ped distance |
| `rsg-beekeeper:server:addQueenBee` | `id` | lock, distance, has queen, conditional `UPDATE ... WHERE active = 0` claim |
| `rsg-beekeeper:server:addHiveResource` | `id, 'food'\|'water'` | lock, distance, active + full, not already 100, has item, atomic increment, refund on failure |
| `rsg-beekeeper:server:harvestHoney` | `id` | lock, distance, owner, honey ≥ 100, has tool, `CanAddItem`, conditional reset claim |
| `rsg-beekeeper:server:pickupBeehive` | `id` | lock, distance, owner, honey rule, `CanAddItem`, conditional `DELETE` |

### Server → client
`spawnBeehive`, `loadBeehives`, `removeBeehive`, `beehiveActivated`, `beehiveFull`, `hiveSmoked`, `hiveCalmExpired`, `colonyDied`, `playSmokerAnim`, `openHiveUI`, `updateHiveUI`, `actionResult`, `hiveGone` (all prefixed `rsg-beekeeper:client:`).

### NUI callbacks
`nuiReady`, `closeBeehiveUI`, `refreshHiveInfo`, `hiveAction` (`addQueenBee`, `addFood`, `addWater`, `harvestHoney`, `pickupBeehive`). They only forward the open hive's id. The server decides everything else.

## 4. Database
Table `rsg_beehives`: `id`, `citizenid`, `x`, `y`, `z`, `heading`, `active`, `activated_at`, `food`, `water`, `health`, `honey`, `smoked_until`, `prop`, `created_at`; index on `citizenid`. Built automatically when `Config.AutoDatabase = true`. Otherwise import `install.sql`.

## 5. Security model
- No item or money changes happen on the client.
- Every action holds a per-player lock (`WithLock`) and claims the hive with a conditional SQL update before handing out items, so spamming events can't duplicate rewards.
- Distance is always measured from the real ped (`GetPlayerPed(src)`), with `Config.ProximityBuffer` leeway.
- Item lookups use `exports['rsg-inventory']:GetItemByName/GetItemBySlot`. Metadata items (smoker, bucket) are removed and re-added with updated uses, falling back to any free slot so they're never lost.

## 6. Server owner how-tos
- **Add a hive style:** add `{ prop, item, label, price }` to `Config.BeeHiveProps`, add the item to `rsg-core/shared/items.lua`, and stream the model.
- **Faster testing:** lower `population.growthIntervalSeconds` and `upkeep.tickIntervalSeconds`.
- **Logging:** set `Config.Webhooks.enabled = true` plus a URL, then run `/beehivewebhook` (ACE `command.beehivewebhook`).

## 7. Troubleshooting
| Problem | Fix |
|---|---|
| "Failed to create/verify the rsg_beehives table" | DB user lacks `CREATE`; import `install.sql` and set `Config.AutoDatabase = false` |
| Using a hive item does nothing | Make sure `rsg-gizmo` is started before rsg-beekeeper |
| Hives invisible | The `stream/` folder or the `DLC_ITYP_REQUEST` entry is missing |
| Can't add food/water | The colony isn't full grown yet (by design) |
| Panel closes by itself | You walked more than `target.distance + 2` m from the hive |

Support: https://buymeacoffee.com/rexshack
