fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'

author 'RexShack'
name 'rsg-beekeeper'
description 'Beekeeper script for RSG Framework'
version '3.0.1'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/webhook.lua',
    'server/server.lua',
    'server/versionchecker.lua'
}

client_scripts {
    'client/placement.lua',
    'client/client.lua'
}

dependencies {
    'rsg-core',
    'rsg-inventory',
    'ox_lib',
    'ox_target',
    'oxmysql',
}

ui_page 'html/index.html'

files {
  'stream/bee_house_gk_ytyp.ytyp',
  'locales/*.json',
  'html/index.html',
  'html/style.css',
  'html/script.js',
}

data_file 'DLC_ITYP_REQUEST' 'stream/bee_house_gk_ytyp.ytyp'

lua54 'yes'
