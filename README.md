# SetAB 0.3.0 (Windower 4 / Lua 5.1)

[日本語](https://github.com/hikaruoshino/SetAB)

SetAB records the damage of your weapon skills, spells and pet abilities for each GearSwap set, and compares the sets. Which set really hits harder? Check it with numbers.

It is **read-only**: it never sends a packet. It records only your own actions and your pet's.

## Install

1. Put `setab.lua` and `setab_stats.lua` in `addons/setab/`
2. In game: `//lua l setab`

## Use

1. Put on the gear you want to compare and name it, e.g. `//setab label Karin` (the same for each set)
2. Fight as usual (results are saved to `data/<your name>/log.csv`)
3. `//setab report Hot Shot` (the action name: English, or Japanese on a Japanese client; a part of the name is enough, and Tab (auto-translate) works. If you do not know what to type, list the names with `//setab actions`. Without a name, all actions are put together)
4. `//setab compare Karin Fotia Hot Shot` (names without spaces are easier to handle). The result goes to the chat, and a table (HUD) opens on the screen

A weapon skill set is worn **only at the moment you use it**, so you cannot label it beforehand. Use the weapon skill once, look up the hash with `//setab sets`, and name it with `//setab name <hash> <name>`.

| Command | What it does |
|---|---|
| `//setab on` / `off` / `status` | Switch recording on or off, show the state |
| `//setab label <name>` | Name the gear you wear now |
| `//setab name <hash> <name>` | Name a set by its hash (see `sets`) |
| `//setab sets` | List the recorded sets |
| `//setab actions [set]` | List the recorded action names with their counts (on a Japanese client: "Japanese name (English name)"). Use it to check what to type after `report` and `compare`. With a set name, only that set's counts |
| `//setab lang ja\|en\|auto` | The language action names are shown in (`auto` = the client's). The names in `log.csv` are always English |
| `//setab report [action]` | Per set: n, mean, median, 95% CI, miss / resist rate. `[action]` is a name from `//setab actions` (English or Japanese, e.g. `Aeolian Edge`). Without it, everything |
| `//setab compare A B [action]` | Difference between two sets and Welch's t. Goes to the chat and opens the table (HUD). Example: `//setab compare Nyame ABMagic Aeolian Edge` (do not type the `<` and `>`). Without `[action]`, different actions get mixed, so a note appears |
| `//setab hud` | Hide / show the table (HUD) |
| `//setab hud on` / `off` | Whether `compare` opens the table (`off` = chat only, and hides it) |
| `//setab hud size <6-40>` | Text size of the table. The mouse wheel changes it too |
| `//setab hud reset` | Put the table back to its first position and size |
| `//setab hud tip on` / `off` | Show / hide the explanations that appear when the pointer is over the table |
| `//setab tp <min> [max]` | Filter by TP range (TP is recorded for weapon skills only) |
| `//setab target <text>` | Filter by enemy name |
| `//setab filter clear` | Clear the filters |
| `//setab ignore <slot>` | Leave a slot out of the set hash (e.g. ammo). Type it again to put it back |
| `//setab reset confirm` | Erase the log |
| `//setab debug on\|off` | For checking: print the raw values of your and your pet's actions (category, param, message) and TP changes to the chat and `data/<your name>/debug.log` |

## The table (HUD)

`//setab compare A B [action]` opens a table on the screen. **A is the top row and B the row below**, with count, mean, median, min, max, half the width of the 95% confidence interval and the miss (resist) rate beside each. Under each row are the damage values in the order they happened (the last 10). At the bottom are the difference of A and B (as a percentage of B), the t value and a verdict on whether there is a difference.

*The screenshots in this section were taken on a Japanese client, so the table and the explanations are in Japanese. On an English client they are in English, as in the text example just below (the headings, the verdict and the explanations). The numbers and the layout are the same.*

![The SetAB table (HUD)](images/hud.png)

```
SetAB  Aeolian Edge   [target=Locus Blazer Elytra TP=3000-3000]
--------------------------------------------------------------------
   set               n     avg     med     min     max     +-ci  miss
A  Nyame             3   36152   38734   30987   38734   +-5061    0%
     dmg 38734 30987 38734
B  ABMagic           3   32344   34416   27532   35084   +-4731    0%
     dmg 35084 34416 27532
--------------------------------------------------------------------
A vs B   diff +3808 (+11.8% of B)   t=1.08
no clear difference yet (|t|<2); collect more samples
```

- **Move it with the mouse.** Drag the table to change its position (the position is saved).
- **Put the pointer over a heading or a number and an explanation appears**: count, mean, median, min, max, the confidence width, miss rate, the damage in order, the difference of A and B, the **t value**, and the verdict each have one. It appears in a separate small box beside the pointer (not while a button is held or while the table is hidden). Turn it off with `//setab hud tip off`.

  ![The t value explanation](images/tooltip_t.png)

  ![The median explanation](images/tooltip_median.png)

- **Resize it with the wheel.** Turn the wheel over the table. While the pointer is on the table, the wheel does not reach the game.
- The table refreshes by itself as new records come in during a fight (at most once a second). It also refreshes when you change the filters with `//setab tp`, `target` or `filter clear`.
- The verdict is color-coded (green: probably a real difference, grey: no clear difference, orange: not enough data).
- On a Japanese client the headings and the verdict are in Japanese (English on an English client; switch with `//setab lang ja` / `en`). The font is MS Gothic on a Japanese client (it is fixed-width and can show Japanese); a full-width character counts as two cells so that the columns line up.

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

- The sentences in the chat are English. Set names and action names are shown in Japanese on a Japanese client (they are converted to Shift-JIS for the chat).
- **Checked in game** (Japanese client, October 2026): weapon skills (single and multi-hit) and TP, black magic and magic bursts, that buffs and trusts are not recorded, the names and damage of pet abilities (beastmaster and summoner), that a pet's buff blood pacts are not recorded, enfeebling spells landing and resisting on enemies, a weapon skill missing, that earrings and rings count in the set, and the gear and TP at the start of a weapon skill.
- **Checked in game for the table (HUD)** (0.3.0, Japanese client, October 2026): that the table opens (A on top, B below, the values beside them), the Japanese headings, an action name typed in Japanese with Tab (auto-translate), the list of actions with their Japanese names (no garbled text), moving the table by dragging, resizing it with the wheel, the explanations that appear over the headings, the t value, the difference and the verdict (and how they wrap), and `//setab hud tip off`, `//setab hud size` and `//setab hud reset`.
- Misses and resists are judged by tables of message numbers (`MISS_MSG` = 188, 282; `RESIST_MSG` = 85, 284, 653-656). I have confirmed miss 188 and resist 85 and 653. The other numbers are not confirmed in game yet. A number that is not in a table is kept raw in the `msg` column, so you can sort them again later.
- **Not checked on the English client yet.**
- Using Windower is not permitted by the FFXI Terms of Service. I cannot guarantee that this addon is allowed or that it will not be detected. Use it at your own risk; the author accepts no responsibility.

## Changelog

* **0.3.0**
  * Putting the pointer over a heading, a number or the t value of the table shows what it means in a separate small box (`//setab hud tip on` / `off`).
  * The headings and the verdict of the table are in Japanese on a Japanese client.
  * Japanese input and output no longer come out garbled on a Japanese client (arguments are converted from Shift-JIS, the chat output to Shift-JIS). Action names are shown by their Japanese names and can be typed in Japanese (Tab works, and a part of the name is enough). `//setab actions` lists the recorded action names. When a set name is wrong, the known set names are shown.
  * `//setab compare` opens a table (HUD) on the screen (A on top, B below, the values beside them, and the difference as a percentage). You can move it with the mouse and resize it with the wheel. `//setab hud` shows and hides it.
* **0.2.4** (first public release)
  * Gear and TP are now read at the start of an action (the weapon skill's start packet). Reading them when the result arrives sometimes recorded the set you swapped back to right after the weapon skill instead of the weapon skill gear. TP is now the TP just before the weapon skill, not the value after it was spent (around 100).
  * An enfeebling spell that works on an enemy is recorded (`land`). In `report`, `miss/resist` for an enfeebling spell is the resist rate (resists / (lands + resists)).
  * Earrings and rings count in the set. Damage is counted only when the message is a damage message.
  * Pet ability names are looked up correctly for summoners and beastmasters.

## Feedback

A one-line "it works" or "it does not" is welcome. You can post from [Issues](../../issues/new/choose).

## License

MIT License. See `LICENSE`.
