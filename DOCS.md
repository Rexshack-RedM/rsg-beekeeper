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
| `locales/*.json` | 11 languages, identical keys |

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

Support the Project : https://rexshack.tebex.store/

<!-- BEGIN AUTO-REFERENCE (generated from the code; re-run the generator instead of editing by hand) -->

## Technical reference

Generated from the source of **rsg-beekeeper 3.2.0**. Names, arguments and defaults below are read straight from the code.

### Dependencies

`rsg-core`, `rsg-inventory`, `rsg-target`, `rsg-gizmo`, `oxmysql`

### Database

Tables: `rsg_beehives`.

Tables are created automatically on start while `Config.AutoDatabase = true` (default). Nothing is ever dropped or overwritten.
For a manual install set `Config.AutoDatabase = false` and import `install.sql` once.

```lua
-- shared/config.lua
Config.AutoDatabase = true -- false = import the SQL file yourself
```

### Configuration

| Option | Default | Notes |
|---|---|---|
| `Config.AutoDatabase` | `true` | install.sql manually instead. |
| `Config.Webhooks` | `table` | entirely -- the webhook module no-ops instead of erroring. |
| `Config.ProximityBuffer` | `3.0` | hard equality check would false-reject legitimate players. |
| `Config.BeeHiveProps` | `table` | through the database as text, so it needs to stay a string the whole way. |
| `Config.Placement` | `table` | Placement uses rsg-gizmo (the framework's standard placement tool). |
| `Config.Beehive` | `table` |  |

### Events

Server events can be fired by any client, so every handler re-validates the player, the arguments and any permission, distance or cooldown on the server. Never add a reward to a handler without those checks.

| Event | Side | Arguments | File |
|---|---|---|---|
| `rsg-beekeeper:client:startPlacement` | client | `prop` | `client/client.lua` |
| `rsg-beekeeper:client:openHiveUI` | client | `data` | `client/client.lua` |
| `rsg-beekeeper:client:updateHiveUI` | client | `data` | `client/client.lua` |
| `rsg-beekeeper:client:actionResult` | client | `data` | `client/client.lua` |
| `rsg-beekeeper:client:hiveGone` | client | `id, message` | `client/client.lua` |
| `rsg-beekeeper:client:spawnBeehive` | client | `data` | `client/client.lua` |
| `rsg-beekeeper:client:loadBeehives` | client | `list` | `client/client.lua` |
| `rsg-beekeeper:client:removeBeehive` | client | `id` | `client/client.lua` |
| `rsg-beekeeper:client:beehiveActivated` | client | `id` | `client/client.lua` |
| `rsg-beekeeper:client:beehiveFull` | client | `id` | `client/client.lua` |
| `rsg-beekeeper:client:hiveSmoked` | client | `id` | `client/client.lua` |
| `rsg-beekeeper:client:hiveCalmExpired` | client | `id` | `client/client.lua` |
| `rsg-beekeeper:client:playSmokerAnim` | client | `hiveCoords` | `client/client.lua` |
| `rsg-beekeeper:client:colonyDied` | client | `id` | `client/client.lua` |
| `RSGCore:Client:OnPlayerLoaded` | client | `` | `client/client.lua` |
| `RSGCore:Client:OnPlayerUnload` | client | `` | `client/client.lua` |
| `rsg-beekeeper:server:placeBeehive` | server | `coords, heading, prop` | `server/server.lua` |
| `rsg-beekeeper:server:requestBeehives` | server | `` | `server/server.lua` |
| `rsg-beekeeper:server:getHiveInfo` | server | `id, isRefresh` | `server/server.lua` |
| `rsg-beekeeper:server:addQueenBee` | server | `id` | `server/server.lua` |
| `rsg-beekeeper:server:addHiveResource` | server | `id, resourceType` | `server/server.lua` |
| `rsg-beekeeper:server:harvestHoney` | server | `id` | `server/server.lua` |
| `rsg-beekeeper:server:pickupBeehive` | server | `id` | `server/server.lua` |

```lua
-- from a client script
TriggerServerEvent('rsg-beekeeper:server:placeBeehive', coords, heading, prop)
-- from a server script
TriggerClientEvent('rsg-beekeeper:client:startPlacement', source, prop)
```

### Commands

| Command | Notes | File |
|---|---|---|
| `/beehivewebhook` |  | `server/webhook.lua` |

### Locales

Language files in `locales/`: `de`, `el`, `en`, `es`, `fr`, `ja`, `nl`, `pl`, `pt-br`, `ro`, `ru`. Set the language with `setr rsg:locale "en"`.

<!-- END AUTO-REFERENCE -->
