# Combo Efficiency Indicator

Shows your combo bonus for random item boxes in Dynasty Warriors 3: Xtreme Legends Complete Edition Remastered.

During battle the word sits above your portrait. `Common` is gray, `Refined` is blue, and `Peerless` fades between yellow and purple. The word can fall as the battle goes on. For the first five minutes the game counts the battle as five minutes long, so the word cannot drop until after that.

## Requirements

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) with Lua mods.

## Install

1. Install UE4SS into `DW3CE_RE\Binaries\Win64` if it is not already there. Its mods folder is `DW3CE_RE\Binaries\Win64\ue4ss\Mods`.
2. Copy this whole `ComboEfficiencyIndicator` folder into that `Mods` folder. The folder name has to stay `ComboEfficiencyIndicator`.
3. Enable the mod. In `Mods\mods.txt`, add this line above the `Keybinds` line:

   ```
   ComboEfficiencyIndicator : 1
   ```

4. If your install lists mods in `Mods\mods.json`, add this entry with the other mods. Put it above `Keybinds` when that entry is present:

   ```json
   {
       "mod_name": "ComboEfficiencyIndicator",
       "mod_enabled": true
   }
   ```

## Files

| File | Role |
| --- | --- |
| `scripts/main.lua` | The mod. |

## When something looks wrong

Logs go to:

`DW3CE_RE\Binaries\Win64\ue4ss\UE4SS.log`

Search for `[Combo Efficiency]`.

A healthy load looks like this:

```
[Combo Efficiency] loaded
[Combo Efficiency] scenario timer 12.3
[Combo Efficiency] perfect 1 great 1 time 24.9 rate 0.067 bonus +1
```

`loaded` means the script started. `scenario timer` is written once, the first time the battle clock can be read. The `perfect` line is written when your combo counts change or when the word changes. `bonus +0` is Common, `+1` is Refined, and `+2` is Peerless.
