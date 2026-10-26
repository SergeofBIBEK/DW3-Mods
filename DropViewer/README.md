# Drop Viewer

Shows an officer's assigned drop in Dynasty Warriors 3: Xtreme Legends Complete Edition Remastered.

Lock on to an officer during battle. The drop name appears under the portrait, in smaller text. When a combo can raise that drop, a gold `8+`, `16+`, or `24+` sits on the next line.

## Requirements

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) with Lua mods.

## Install

1. Install UE4SS into `DW3CE_RE\Binaries\Win64` if it is not already there. Its mods folder is `DW3CE_RE\Binaries\Win64\ue4ss\Mods`.
2. Copy this whole `DropViewer` folder into that `Mods` folder. The folder name has to stay `DropViewer`.
3. Enable the mod. In `Mods\mods.txt`, add this line above the `Keybinds` line:

   ```
   DropViewer : 1
   ```

4. If your install lists mods in `Mods\mods.json`, add this entry with the other mods. Put it above `Keybinds` when that entry is present:

   ```json
   {
       "mod_name": "DropViewer",
       "mod_enabled": true
   }
   ```

## Files

| File | Role |
| --- | --- |
| `scripts/main.lua` | The mod. |
| `scripts/read_i32.dll` | Reads the current battle's drop list. |

## When something looks wrong

Logs go to:

`DW3CE_RE\Binaries\Win64\ue4ss\UE4SS.log`

Search for `[Drop Viewer]`.

A healthy load looks like this:

```
[Drop Viewer] loaded script=...\\DropViewer\\scripts reader=bound
[Drop Viewer] drop cache ready count=120
```

`reader=bound` means the DLL loaded and the cache folder is writable. `drop cache ready` means that battle's drop list was read. The number is how many records were read. One line is written each time a battle's list is installed.
