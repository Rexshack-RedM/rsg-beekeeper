# rsg-beekeeper

A beekeeping script for RedM, built on the RSG Framework. Players place beehives, start a colony with a queen bee, keep it fed and watered, calm it with a smoker, and harvest honey and beeswax once the colony is fully grown.

## Features

- **Placeable beehives** -- 6 prop styles (`bee_house_gk_1` to `bee_house_gk_6`), each with its own inventory item. Placement shows a ghost hive on the ground in front of you that follows as you walk, with a green/red ring and a small HUD showing whether the spot is valid.
- **Queen bee activation** -- a placed hive stays empty until a queen bee is added through the management panel.
- **Population growth** -- bees arrive gradually over real time up to a configurable max. Growth is worked out from a timestamp, so it carries on across restarts with no ticking loop.
- **Food / water / health upkeep** -- a fully grown colony uses food and water on a fixed tick. If either runs out, health drains; once both are topped up, health recovers. The whole tick runs as a single database update, so it stays cheap with hundreds of hives. At 0 health the colony and queen die, but the hive stays placed and can be requeened.
- **Bee smoker** -- use a smoker near a swarming hive to calm it for 15 minutes (configurable). Calm hives use a docile particle effect and don't sting. Angry hives sting anyone standing too close. Each smoker has 20 uses (configurable).
- **Honey harvesting** -- when a fed colony's honey reaches 100%, its owner can harvest honeycomb and beeswax with a honey scrapper (not consumed).
- **Management panel** -- a draggable panel opened with `rsg-target` shows population, food, water, health and honey, refreshes live while open, and closes itself if you walk away. Picking up a hive needs a confirming second click. Other players can help feed and water a hive, but only the owner can harvest or pick it up.
- **Distance streaming** -- hives only exist as world objects when a player is within `Config.Beehive.renderDistance`, so lots of hives across the map cost nothing for players far away.
- **Per-player hive cap** -- optional limit on how many hives one character can have placed.
- **Discord webhook logging** -- optional per-event webhooks for placing, activating, harvesting, picking up and colony deaths, plus an admin test command.
- **Server-side validation** -- every action re-checks distance, ownership and item possession on the server, holds a per-player action lock, and uses conditional database updates so rewards and refunds can't be duplicated by spamming events. Inventory space is checked before harvesting or picking up, so items are never lost to a full inventory.
- **Automatic database setup** -- the `rsg_beehives` table is created on resource start.
- **Version checker** -- warns in the server console when a newer version is available.

## Dependencies

- [`rsg-core`](https://github.com/Rexshack-RedM/rsg-core)
- [`rsg-inventory`](https://github.com/Rexshack-RedM/rsg-inventory)
- [`rsg-target`](https://github.com/Rexshack-RedM/rsg-target)
- [`oxmysql`](https://github.com/overextended/oxmysql)

## Installation

1. Copy the resource into your resources folder (e.g. `resources/[rsg]/rsg-beekeeper`).

2. Add it to `server.cfg` after its dependencies:

   ```cfg
   ensure oxmysql
   ensure rsg-core
   ensure rsg-inventory
   ensure rsg-target
   ensure rsg-beekeeper
   ```

3. **Database** -- nothing to do. The `rsg_beehives` table is created automatically on first start (the database user needs `CREATE` permission). `installation/rsg_beehives.sql` is included if you'd rather import it yourself.

4. **Items** -- copy the entries from `installation/items.lua` into `rsg-core/shared/items.lua`, and the images from `installation/images/` into your inventory's image folder:
   - `beehive_gk_1` .. `beehive_gk_6` -- placeable hives
   - `queen_bee` -- starts a colony
   - `beefood` -- tops up food
   - (uses your existing `fullbucket` item for water -- not included)
   - `honey_scrapper` -- needed to harvest (not consumed)
   - `honey_comb`, `beeswax` -- harvest rewards
   - `beesmoker` -- calms a swarming hive (20 uses)

5. Restart the server. The stream files and their `DLC_ITYP_REQUEST` entry are already set up in `fxmanifest.lua`.

## Configuration

All settings are in `shared/config.lua`.

### Webhooks (`Config.Webhooks`)

Disabled by default. To enable:

```lua
Config.Webhooks = {
    enabled = true,
    url = 'https://discord.com/api/webhooks/...', -- used by any event without its own url
    botName = 'RSG Beekeeper',
    botAvatar = '',
    events = {
        placed    = { enabled = true, url = '', color = 0xE0A030 },
        activated = { enabled = true, url = '', color = 0xF1C40F },
        harvested = { enabled = true, url = '', color = 0xE67E22 },
        died      = { enabled = true, url = '', color = 0xE74C3C },
        pickedup  = { enabled = true, url = '', color = 0x8B5A2B },
        test      = { enabled = true, url = '', color = 0x3498DB },
    },
}
```

Test it in-game with `/beehivewebhook` (admin only):

```cfg
add_ace group.admin command.beehivewebhook allow
```

### General

| Setting | Default | Description |
|---|---|---|
| `Config.ProximityBuffer` | `3.0` | Extra metres allowed on server distance checks for network drift |
| `queenBeeItem` | `queen_bee` | Item used to start a colony |
| `prop` | `bee_house_gk_1` | Fallback prop if a hive's stored prop can't load |
| `maxHivesPerPlayer` | `5` | Max hives per character (`0` = unlimited) |
| `blockPickupWithHoney` | `true` | Refuse pickup while honey is ready to harvest, so it isn't lost |
| `renderDistance` | `100.0` | Distance at which hives spawn/despawn for a player |
| `target.icon` / `target.distance` | `fas fa-bug` / `2.5` | `rsg-target` icon and interaction range |

### Placement (`Config.Placement`)

Controls: **LMB** place, **Left / Right** rotate, **Up / Down** height, **RMB / Backspace** cancel. While placing, a panel in the top left shows the keys, the current heading and height, and live feedback on whether the spot is valid (and why not). Placement is blocked in water and inside interiors.

| Setting | Default | Description |
|---|---|---|
| `placeDistance` | `1.5` | Metres in front of the player the ghost hive sits |
| `maxDistance` | `6.0` | Server-side sanity check on how far from the player a hive can be placed |
| `minHiveSpacing` | `2.0` | Minimum distance between two hives (checked on client and server) |
| `heightMax` | `0.5` | Max height adjustment up or down |
| `heightSpeed` | `0.3` | Metres per second while holding Up/Down |
| `rotateSpeed` | `90.0` | Degrees per second while holding Left/Right |
| `ringRadius` | `0.6` | Size of the valid/invalid ring |

### Beehive props (`Config.BeeHiveProps`)

Each entry links a prop model (a string) to the item that places it. `price` is informational for your shop.

```lua
{ prop = 'bee_house_gk_1', item = 'beehive_gk_1', label = 'Bee House (Style 1)', price = 250 },
```

### Population (`Config.Beehive.population`)

- `max` (`200`) -- max bees in a hive
- `growthIntervalSeconds` (`60`) -- real seconds between each growth step
- `beesPerInterval` (`5`) -- bees added each growth step (time to full = `growthIntervalSeconds` x `max / beesPerInterval`, rounded up)

### Upkeep (`Config.Beehive.upkeep`)

- `foodItem` (`beefood`) -- item used to add food
- `tickIntervalSeconds` (`300`) -- how often upkeep runs
- `foodDecayPerTick` / `waterDecayPerTick` (`5`) -- % lost per tick
- `healthDecayPerTick` (`1`) -- health lost per tick while food or water is at 0
- `healthRegenPerTick` (`1`) -- health regained per tick while both are above 0
- `foodPerItem` (`25`) -- % food added per item
- `waterItem` (`fullbucket`) -- item used to add water
- `waterReturnItem` (`bucket`) -- empty item handed back after pouring (`''` to give nothing back; skipped if the item doesn't exist)
- `waterPerItem` (`25`) -- % water added per bucket use
- `waterTotalUses` (`5`) / `waterUsesKey` (`uses`) -- a full bucket is poured one use at a time; uses are read from the bucket's metadata, falling back to `waterTotalUses`

Food and water can only be added once a colony is fully grown, since a growing colony doesn't use them.

### Honey (`Config.Beehive.honey`)

- `harvestTool` (`honey_scrapper`) -- required to harvest, not consumed
- `honeyCombItem` / `beeswaxItem` -- reward items
- `honeyCombAmount` / `beeswaxAmount` (`2` / `1`) -- amount per harvest
- `honeyPerTick` (`5`) -- % honey made per tick while fed

### Smoker (`Config.Beehive.smoker`)

- `item` (`beesmoker`) -- smoker item
- `totalUses` (`20`) -- uses per smoker
- `calmDurationSeconds` (`900`) -- how long a hive stays calm
- `angryPtfx` / `calmPtfx` -- particle effects for angry and calm swarms
- `dangerRadius` (`4.0`) -- sting range around an angry hive
- `damageAmount` (`5`) -- health lost per sting
- `damageIntervalMs` (`3000`) -- time between stings
- `minHealthFraction` (`0.3`) -- stings never take a player below this share of max health
- `animScenario` (`WORLD_HUMAN_CROUCH_INSPECT`) / `animDurationMs` (`4000`) -- scenario played while smoking a hive (`''` to disable)

## Locales

All player-facing text -- notifications, the placement help bar, the `rsg-target` label, the management panel and the Discord webhook embeds -- lives in `locales/*.json` and is loaded by rsg-core (`@rsg-core/shared/locale.lua`). The panel gets its text from Lua when it opens, so it follows the same language.

Included languages: `en`, `de`, `el`, `es`, `fr`, `ja`, `nl`, `pl`, `pt-br`, `ro`.

Set the server language in `server.cfg` (falls back to `ox:locale`, then `en`):

```cfg
setr rsg:locale de
```

To add another language, copy `locales/en.json` to `locales/<code>.json` and translate the values. Keep every key, and keep each `%s` placeholder in the same order.

## Support

Support: https://buymeacoffee.com/rexshack
