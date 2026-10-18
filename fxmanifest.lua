fx_version 'cerulean'
game 'gta5'
description 'custom_id (tiny): unique IDs + Discord username above heads (hold B), Spookyy font'
version '2.1.0'
dependencies { 'qb-core', 'oxmysql' }
server_scripts { '@oxmysql/lib/MySQL.lua', 'server.lua' }
client_script 'client.lua'
ui_page 'html/index.html'
files { 'html/index.html', 'html/Spookyy.otf', 'html/fonts/*' }
