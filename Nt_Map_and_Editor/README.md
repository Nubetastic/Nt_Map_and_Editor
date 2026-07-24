# Nt Map and Editor

## [Showcase](https://www.youtube.com/watch?v=qjWJmajmwZ8)

RedM imap list and standalone imap tool

Config.EnableEditor = false, to disable the tool.

Imaps have 3 settings.
D = default = true, the imap is skipped, it is not requested or removed.
+ = enable = true, RequestImap for this hash.
- = enable = false, RemoveImap for this hash.

## Install
Replace your existing imap loader with this script.
If you use RSG it is in the "[mapmods]" folder.
Ensure the script or folder it is in in server.cfg
Start Server.


### Editor UI
Command: /viewimaps
You can set the distance you want Imaps to load from your players coords.
As you move around it will load and unload imaps. You can use the Lock check box to stop it from updating.

D : Does not load or unload, it just reflects the script skips this.
    - if a hash is set as D originally and then reset it is not enabled or disabled, it is skipped.
+ : Loads the Imap
- : Removes the Imap
Hand: Holds the Imap position. This keeps the imap from resetting.
    - This allows you to load and unload as you see fit, hold the ones you want to keep and reset to see what it will look like.

Reset - will reset all imap values to imapConfig.lua values.
Export - You imap changes will update to imap_changes.json live, export will take this list and compile a new imapConfig.lua file in imapConfig_update.lua. Just copy and replace the text from the update file into the original file.

## Building From a Custom iMap List
You can use the existing imapConfig.lua, it is what i am using, or replace it easily with your current imap list using a powershell script detailed below.

The PowerShell helper builds `shared/imapConfig.lua` from an `imaplist.lua` loader file and `IMAP_CATALOG.lua` reference data in the tools folder.

To use a custom list by replacing the imap list in tools\imaplist.lua
**DO NOT EDIT IMAP_CATALOG.lua** This file is used to populate coords for each hash.
Bottom values are kept.
RequestImap(1858796535) -- Above value becomes overwritten
RemoveImap(1858796535)  --  by bottom value with the same hash in imapConfig.lua

You can use this method to easily update a whole town from one imap list to another.

I execute the following powershell command in Visual Studio Code, Terminal.
```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build_imap_config.ps1
```

The script writes:

- `shared/imapConfig.lua` - generated iMap config used by the resource
- `tools/imap_merge_report.md` - summary of parsed entries, duplicates, and missing catalog matches

### Special Thanks
Imap data was gathered from these 3 sources.
Brits_interiors - https://forum.cfx.re/t/brits-ipl-for-a-cleaner-more-expansive-environment/3385879
Redm-ImapViewer - https://github.com/robwhitewick/Redm-ImapViewer
psn_interiors - https://github.com/Hailey-Ross/psn_interiors/tree/main