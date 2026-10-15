Config = {}

-- Discord webhook logging. Each event has its own on/off switch and optional
-- URL override; anything left blank falls back to Config.Webhooks.url. Leave
-- Config.Webhooks.enabled = false (or every URL blank) to disable logging
-- entirely -- the webhook module no-ops instead of erroring.
Config.Webhooks = {
    enabled   = false,   -- master switch
    url       = '',      -- default webhook URL used by any event below without its own url
    botName   = 'RSG Beekeeper',
    botAvatar = '',       -- optional avatar image URL for the webhook bot

    events = {
        -- A new beehive was placed in the world.
        placed = {
            enabled = true,
            url     = '',       -- overrides Config.Webhooks.url if set
            color   = 0xE0A030, -- amber
        },
        -- A queen bee was added, activating a hive.
        activated = {
            enabled = true,
            url     = '',
            color   = 0xF1C40F, -- yellow
        },
        -- Honey/beeswax harvested from a full hive.
        harvested = {
            enabled = true,
            url     = '',
            color   = 0xE67E22, -- orange
        },
        -- A hive's health hit 0 (starved/dehydrated) -- the colony and queen
        -- died, but the hive structure itself was NOT deleted; it's now
        -- empty/inactive and waiting on a new queen bee.
        died = {
            enabled = true,
            url     = '',
            color   = 0xE74C3C, -- red
        },
        -- A beehive was picked back up by its owner and removed from the world.
        pickedup = {
            enabled = true,
            url     = '',
            color   = 0x8B5A2B, -- brown
        },
        -- Used only by the /beehivewebhook admin test command.
        test = {
            enabled = true,
            url     = '',
            color   = 0x3498DB, -- blue
        },
    },
}

-- Extra leeway (in metres) added on top of interaction distances when the
-- server double-checks how far a player actually is from something -- client
-- and server positions can drift slightly due to latency/interpolation, so a
-- hard equality check would false-reject legitimate players.
Config.ProximityBuffer = 3.0

-- Pool of beehive prop models. Each one has its own purchasable/useable item.
-- Using an item tied to a specific entry places that entry's prop model, and
-- each prop's ox_target interaction is registered from this list too.
--
-- NOTE: prop must be a plain string (the model name), not a backtick hash
-- literal -- it gets hashed client-side with joaat() and also round-trips
-- through the database as text, so it needs to stay a string the whole way.
Config.BeeHiveProps = {
    { prop = 'bee_house_gk_1', item = 'beehive_gk_1', label = 'Bee House (Style 1)', price = 250 },
    { prop = 'bee_house_gk_2', item = 'beehive_gk_2', label = 'Bee House (Style 2)', price = 250 },
    { prop = 'bee_house_gk_3', item = 'beehive_gk_3', label = 'Bee House (Style 3)', price = 250 },
    { prop = 'bee_house_gk_4', item = 'beehive_gk_4', label = 'Bee House (Style 4)', price = 250 },
    { prop = 'bee_house_gk_5', item = 'beehive_gk_5', label = 'Bee House (Style 5)', price = 250 },
    { prop = 'bee_house_gk_6', item = 'beehive_gk_6', label = 'Bee House (Style 6)', price = 250 },
}

-- Simple placement: the hive ghost sits on the ground in front of the player
-- and follows them. Walk/turn to position it. Controls:
-- [LMB] place, [Left / Right] rotate, [Up / Down] height, [RMB / Backspace] cancel.
Config.Placement = {
    placeDistance  = 1.5,   -- metres in front of the player the hive is placed
    maxDistance    = 6.0,   -- server-side sanity check on placement distance
    minHiveSpacing = 2.0,   -- min distance between two hives
    heightMax      = 0.5,   -- max height offset up/down from the ground
    heightSpeed    = 0.3,   -- metres per second while holding Up/Down
    rotateSpeed    = 90.0,  -- degrees per second while holding Left/Right
    ringRadius     = 0.6,   -- radius of the valid/invalid ring drawn under the ghost
}

Config.Beehive = {
    queenBeeItem      = 'queen_bee',  -- item name consumed to activate a placed hive
    prop              = 'bee_house_gk_1', -- fallback prop model (used if a hive has no stored/valid prop)
    maxHivesPerPlayer = 5,             -- max hives a single citizen can have placed at once (0 = unlimited)
    renderDistance = 100.0,     -- hives only spawn as world objects when the player is within this many metres

    target = {
        icon     = 'fas fa-bug',     -- ox_target option icon (FontAwesome)
        distance = 2.5,              -- max interaction distance
    },

    population = {
        max                    = 200, -- max bees a hive can hold
        growthIntervalSeconds  = 60,  -- how often the hive attracts more bees (real seconds)
        beesPerInterval        = 5,   -- how many bees are added each growthIntervalSeconds
    },

    -- Food/water/health upkeep. A hive ticks down on a fixed interval rather
    -- than being derived from timestamps (unlike population), since food and
    -- water can be topped up by players at any time and need a simple,
    -- reliably-persisted running value.
    upkeep = {
        foodItem            = 'beefood', -- item consumed to refill food
        waterItem           = 'fullbucket', -- item consumed to refill water
        waterReturnItem     = 'bucket',  -- empty item given back after pouring ('' to give nothing back)
        waterTotalUses      = 5,         -- uses a full bucket has if its metadata has no uses count yet
        waterUsesKey        = 'uses',    -- metadata key that stores the bucket's remaining uses
        tickIntervalSeconds = 300,       -- how often food/water/health tick (5 min)
        foodDecayPerTick    = 5,         -- % food lost per tick
        waterDecayPerTick   = 5,         -- % water lost per tick
        healthDecayPerTick  = 1,         -- health lost per tick while food OR water is at 0
        healthRegenPerTick  = 1,         -- health regained per tick while both food AND water are above 0
        foodPerItem         = 25,        -- % food added when using 1x foodItem
        waterPerItem        = 25,        -- % water added when using 1x waterItem
    },

    -- Honey production. Only starts once population is at max, and only
    -- progresses on ticks where the hive is fed (food AND water above 0) --
    -- ties into the same tick loop as upkeep, using upkeep.tickIntervalSeconds.
    honey = {
        harvestTool     = 'honey_scrapper', -- tool the player must be holding, not consumed
        honeyCombItem   = 'honey_comb',     -- reward item
        beeswaxItem     = 'beeswax',        -- reward item
        honeyCombAmount = 2,                -- amount of honey_comb given per harvest
        beeswaxAmount   = 1,                -- amount of beeswax given per harvest
        honeyPerTick    = 5,                -- % honey produced per tick while full population and fed
    },

    -- Bee smoker. Once a full-population hive is smoked its bees calm down --
    -- the swarm ptfx swaps to a docile variant and the player can no longer
    -- be stung -- for a fixed duration, after which it reverts back to angry
    -- automatically (persisted server-side via smoked_until, so it survives
    -- restarts and doesn't require anyone standing nearby to flip back).
    smoker = {
        item                = 'beesmoker',            -- item used to calm a hive
        totalUses           = 20,                     -- puffs a single smoker has before it's used up and removed
        calmDurationSeconds = 15 * 60,                 -- how long the calm effect lasts (15 min)
        angryPtfx           = 'ent_amb_insect_bee_swarm', -- ptfx while unsmoked/expired
        calmPtfx            = 'ent_amb_insect_bees',      -- ptfx while smoked/calm
        dangerRadius        = 4.0,    -- distance (metres) within which an angry hive can sting the player
        damageAmount        = 5,      -- ped health lost per damage tick while too close to an angry hive
        damageIntervalMs    = 3000,   -- how often (ms) damage is applied while in range of an angry hive
        minHealthFraction   = 0.3,    -- stings never drop the ped below this fraction of max health
    },
}
