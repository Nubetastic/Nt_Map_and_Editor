game 'rdr3'
fx_version 'adamant'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'


version '1.0.0'

ui_page 'html/index.html'
shared_scripts {
	'shared/config.lua',
	'shared/imapConfig.lua'
 }
client_scripts {
	'Map Loaded/client.lua',
	'Map Loaded/interiors.lua',
	'Map Editor/client.lua',
}
server_scripts {
	'Map Editor/server.lua'
}
files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}
