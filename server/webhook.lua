--------------------------------------------------------------------------------------------------
-- rsg-beekeeper :: Discord webhook logging
--
-- Small self-contained module -- exposes BeekeeperWebhook.Send(eventName, title,
-- description, fields) globally for server.lua to call into. Queued and rate-limited
-- so a burst of events (e.g. several players placing hives at once) can't get the
-- webhook URL throttled/banned by Discord.
--------------------------------------------------------------------------------------------------

lib.locale()

BeekeeperWebhook = {}

local queue = {}
local processing = false

-- Discord soft-limits a single webhook to ~30 requests/minute. 1.2s spacing
-- keeps well under that even during bursts, at the cost of events landing in
-- Discord slightly out of real-time order under heavy load.
local SEND_INTERVAL_MS = 1200

local function ProcessQueue()
    if processing then return end
    processing = true

    CreateThread(function()
        while #queue > 0 do
            local job = table.remove(queue, 1)

            local ok, err = pcall(function()
                PerformHttpRequest(job.url, function(statusCode)
                    if statusCode ~= 200 and statusCode ~= 204 then
                        print(('[rsg-beekeeper] ^1%s^7'):format(locale('webhook_post_failed'):format(tostring(statusCode), job.event)))
                    end
                end, 'POST', json.encode(job.payload), { ['Content-Type'] = 'application/json' })
            end)

            if not ok then
                print(('[rsg-beekeeper] ^1%s^7'):format(locale('webhook_request_error'):format(job.event, tostring(err))))
            end

            if #queue > 0 then
                Wait(SEND_INTERVAL_MS)
            end
        end

        processing = false
    end)
end

local function ResolveEventConfig(eventName)
    local cfg = Config.Webhooks
    if not cfg or not cfg.enabled then return nil end

    local eventCfg = cfg.events and cfg.events[eventName]
    if not eventCfg or not eventCfg.enabled then return nil end

    local url = (eventCfg.url and eventCfg.url ~= '') and eventCfg.url or cfg.url
    if not url or url == '' then return nil end

    return eventCfg, url
end

-- fields: array of { name = string, value = string, inline = bool } (ox_lib/Discord embed field format)
function BeekeeperWebhook.Send(eventName, title, description, fields)
    local eventCfg, url = ResolveEventConfig(eventName)
    if not url then return end

    local payload = {
        username = (Config.Webhooks.botName and Config.Webhooks.botName ~= '') and Config.Webhooks.botName or locale('webhook_default_bot_name'),
        avatar_url = (Config.Webhooks.botAvatar and Config.Webhooks.botAvatar ~= '') and Config.Webhooks.botAvatar or nil,
        embeds = {
            {
                title = title,
                description = description,
                color = eventCfg.color or 0xE0A030,
                fields = fields or {},
                footer = { text = 'rsg-beekeeper' },
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            },
        },
    }

    queue[#queue + 1] = { url = url, payload = payload, event = eventName }
    ProcessQueue()
end

--------------------------------------------------------------------------------------------------
-- Admin test command
--------------------------------------------------------------------------------------------------

-- Restricted (last arg `true`) -- grant with an ACE permission, e.g.:
--   add_ace group.admin command.beehivewebhook allow
--   add_principal identifier.xxxx group.admin
RegisterCommand('beehivewebhook', function(source)
    if source == 0 then
        print(('[rsg-beekeeper] %s'):format(locale('webhook_admin_console_warning')))
        return
    end

    local cfg = Config.Webhooks
    if not cfg or not cfg.enabled then
        TriggerClientEvent('ox_lib:notify', source, { title = locale('title_beehive_webhooks'), description = locale('webhook_disabled'), type = 'error' })
        return
    end

    BeekeeperWebhook.Send('test', locale('webhook_test_title'), locale('webhook_test_description'), {
        { name = locale('webhook_field_triggered_by'), value = GetPlayerName(source) or locale('unknown_value'), inline = true },
    })

    TriggerClientEvent('ox_lib:notify', source, { title = locale('title_beehive_webhooks'), description = locale('webhook_test_queued'), type = 'success' })
end, true)
