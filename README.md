# SetAB 0.2.4 (Windower 4 / Lua 5.1)

[日本語](https://github.com/hikaruoshino/SetAB)

SetAB records the damage of your weapon skills, spells and pet abilities for each GearSwap set, and compares the sets. Which set really hits harder? Check it with numbers.

It is **read-only**: it never sends a packet. It records only your own actions and your pet's.

## Install

1. Put `setab.lua` and `setab_stats.lua` in `addons/setab/`
2. In game: `//lua l setab`

## Use

1. Put on the gear you want to compare and name it, e.g. `//setab label Karin` (the same for each set)
2. Fight as usual (results are saved to `data/<your name>/log.csv`)
3. `//setab report Hot Shot` (use the English ability name)
4. `//setab compare Karin Fotia Hot Shot` (names without spaces are easier to handle)

A weapon skill set is worn **only at the moment you use it**, so you cannot label it beforehand. Use the weapon skill once, look up the hash with `//setab sets`, and name it with `//setab name <hash> <name>`.

| Command | What it does |
|---|---|
| `//setab on` / `off` / `status` | Switch recording on or off, show the state |
| `//setab label <name>` | Name the gear you wear now |
| `//setab name <hash> <name>` | Name a set by its hash (see `sets`) |
| `//setab sets` | List the recorded sets |
| `//setab report [action]` | Per set: n, mean, median, 95% CI, miss / resist rate |
| `//setab compare <A> <B> [action]` | Difference between two sets and Welch's t |
| `//setab tp <min> [max]` | Filter by TP range (TP is recorded for weapon skills only) |
| `//setab target <text>` | Filter by enemy name |
| `//setab filter clear` | Clear the filters |
| `//setab ignore <slot>` | Leave a slot out of the set hash (e.g. ammo). Type it again to put it back |
| `//setab reset confirm` | Erase the log |
| `//setab debug on\|off` | For checking: print the raw values of your and your pet's actions (category, param, message) and TP changes to the chat and `data/<your name>/debug.log` |

## What is recorded

One line of `log.csv` is one action's result on one enemy (an area attack adds one line per enemy hit).

`ts, zone, target, actor, action, cat, set, hash, tp, weather, day, buffs, result, dmg, msg, hits`

- `result`: `hit` (damage) / `miss` / `resist` / `land` (an enfeebling spell that worked on an enemy)
- A multi-hit weapon skill or pet ability is recorded as one line with the total of all hits (`hits` is the number that landed).
- Spells are recorded only when the message is a damage message (buffs, haste and so on are not recorded). A pet's buff (ward) blood pact is not recorded either.
- `tp` is the TP **just before** the weapon skill.
- `set` / `hash` is the gear **at the start** of the action. Even if the swap back to your idle gear arrives before the result, it is not mixed up with the weapon skill gear.
- The set is judged by item IDs and augments (earrings and rings included). Changing ammo makes a different set; use `//setab ignore ammo` to leave it out.

## Tips for comparing

- Damage varies a lot. Do not conclude from a few samples (`compare` treats |t| < 2 as no difference).
- **Compare on the same enemy at the same TP.** The enemy's magic defense and resistances change the numbers a lot, even with the same gear. Narrow down with `//setab target` and `//setab tp`. A TP 3000 weapon skill gives nearly fixed damage steps, which makes it easy to compare.
- Debuffs on the enemy (Geo-Malaise and so on) are not recorded. Keep track of when they were on. The weather and day go into the `weather` and `day` columns.

## Limits and notes

- Chat output is English (ASCII) only.
- **Checked in game** (Japanese client, October 2026): weapon skills (single and multi-hit) and TP, black magic and magic bursts, that buffs and trusts are not recorded, the names and damage of pet abilities (beastmaster and summoner), that a pet's buff blood pacts are not recorded, enfeebling spells landing and resisting on enemies, a weapon skill missing, that earrings and rings count in the set, and the gear and TP at the start of a weapon skill.
- Misses and resists are judged by tables of message numbers (`MISS_MSG` = 188, 282; `RESIST_MSG` = 85, 284, 653-656). I have confirmed miss 188 and resist 85 and 653. The other numbers are not confirmed in game yet. A number that is not in a table is kept raw in the `msg` column, so you can sort them again later.
- **Not checked on the English client yet.**
- Using Windower is not permitted by the FFXI Terms of Service. I cannot guarantee that this addon is allowed or that it will not be detected. Use it at your own risk; the author accepts no responsibility.

## Changelog

* **0.2.4** (first public release)
  * Gear and TP are now read at the start of an action (the weapon skill's start packet). Reading them when the result arrives sometimes recorded the set you swapped back to right after the weapon skill instead of the weapon skill gear. TP is now the TP just before the weapon skill, not the value after it was spent (around 100).
  * An enfeebling spell that works on an enemy is recorded (`land`). In `report`, `miss/resist` for an enfeebling spell is the resist rate (resists / (lands + resists)).
  * Earrings and rings count in the set. Damage is counted only when the message is a damage message.
  * Pet ability names are looked up correctly for summoners and beastmasters.

## Feedback

A one-line "it works" or "it does not" is welcome. You can post from [Issues](../../issues/new/choose).

## License

MIT License. See `LICENSE`.
