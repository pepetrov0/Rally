# Rally

*Raid buff assignments for all classes — PallyPower-style, but simple*

![WoW WotLK 3.3.5a](https://img.shields.io/badge/WoW-Wrath%20of%20the%20Lich%20King%203.3.5a-9b1c1c?style=flat-square)
![Version](https://img.shields.io/badge/version-1.2-blue?style=flat-square)

[Features](#features) • [Installation](#installation) • [Usage](#usage) • [How buffing works](#how-buffing-works) • [PallyPower integration](#pallypower-integration)

A lightweight buff-assignment and one-button buffing addon for World of Warcraft: Wrath of the Lich King (3.3.5a). Plan the paladin blessings and warrior shouts in a compact grid, sync them across the raid, then single left-click to buff — Rally walks the raid, finds whoever is missing an assigned buff, and casts it. The button stays on screen and shows how many buffs are still missing.

## Features

- 🎯 **One-button buffing** — an always-visible button that shows the missing-buff count and casts the next buff; dead, offline and out-of-range raiders are ignored until they qualify again
- ⏳ **Timer and refresh** — the button shows the lowest time left on your buffs (green, red under 10% of the duration), also in combat; with nobody missing, every click recasts the buff that runs out first
- 👥 **Raider list on hover** — hovering the button lists everyone scanned with a timer on the right, or `missing`, `DEAD`, `OFF`, `OOR`
- ⚰️ **Resurrections first** — paladins, priests, shamans and druids get "N dead!" on the button before any buff; click to resurrect a random dead raider in range, and if the cast fails the next one is tried
- 📊 **Buff bar** — a column of buff icons for the buffs you should have: grayed out while missing, in colour with the time left while active; only buffs whose caster class is in the group are shown; Well Fed, flask or elixir, and the pet's Well Fed (hunters and warlocks) lead the bar. Hover an icon for the buff tooltip. Shift-drag to move (snaps to the screen centre lines); right-click for horizontal layout, text side, icon size and text size
- 🛡️ **Only paladins and warriors need planning** — blessings per target class for paladins, raid-wide shout rows for warriors; druids cast Wild + Thorns on everyone; every other buffer class casts its standard buff automatically
- 🔄 **Live raid sync** — assignments broadcast over addon messages; only the raid leader or an assistant can edit them
- 🤝 **PallyPower bridge** — shares the paladin grid with PallyPower users, in both directions
- 🧪 **Reagent-aware** — casts greater blessings when reagents are available, falls back to the single-target version when they're not
- ⏱️ **Fresh-buff awareness** — buffs with less than 60 seconds remaining count as missing, so you rebuff ahead of the fall-off
- 🎨 **ElvUI compatible** — optional skin restyles the window, cells, and buttons (no hard dependency)

## Installation

1. Copy the `Rally` folder to your `Interface/AddOns` directory.
2. Make sure the addon is enabled in the character selection screen's addon list.
3. (Optional) Install [ElvUI](https://www.curseforge.com/wow/addons/elvui) — Rally picks it up automatically.

## Usage

### Slash commands

| Command | Action |
|---|---|
| `/rally` | Toggle the assignment window |
| `/rally auto` | Auto-assign blessings to every paladin and shouts to warriors (leader/assistant only) |
| `/rally reset` | Clear all assignments |
| `/rally buffbar on\|off` | Show or hide the buff bar |
| `/rally log` | Log every sync addon message (RALLY and PallyPower, sent and received) to the chat window |
| `/rally debug` | Preview the window and cast button with a fake raid |

> [!TIP]
> Run `/rally debug` anywhere — even solo in a city — to try the full UI. It uses a throwaway fake raid and never touches your real assignments.

### The cast button

An always-visible secure button that states the buff state right on it:

- **Left-click** — cast the next missing buff (greater version first, lesser fallback without reagents); when nothing is missing, refresh the buff with the least time left, then the next lowest on each click
- **Hover** — the list above the button shows every scanned raider with their icon and a timer on the right (`missing` first, then least time left), or `DEAD`, `OFF` or `OOR`
- **Right-click** — toggle the assignment window
- **Shift-drag** — move the button (position is remembered)

The lowest time left on your buffs is shown at the right edge of the button, green and turning red under 10% of that buff's duration. It reads "All good." when everything is covered; otherwise it shows a "N missing!" count, and its icon says which buff it would cast next — while buffs are missing, the button slowly flashes white. The list above the button shows who still needs what until then.

**In combat** the secure button can't change its target, so it is armed just before the pull with what needs no target choice: shouts and Horn of Winter, plus the group buffs (priest prayers, Gift of the Wild, Arcane Brilliance) when you have the reagents for five casts each. Paladins get one representative per assigned class and each click steps to the next. Whatever can't be armed waits until combat ends, and the list only shows what the armed button can cast. Thorns is only cast in groups of 10 or fewer.

### The assignment window

One row per paladin or warrior, one column per target class:

- **Click** a cell — cycle to the next blessing (paladins) or shout (warriors)
- **Shift-click** — set the whole paladin row at once; warrior rows are always set as a whole
- **Right-click** — cycle to the previous blessing
- **Hover** — tooltip showing the exact spells the cell casts

## How buffing works

Paladins get blessing assignments and warriors raid-wide shout assignments through the window. Everyone else needs no planning — their standard buffs are presumed:

| Class | Casts |
|---|---|
| Paladin | Assigned blessings (Kings / Might / Wisdom / Sanctuary) |
| Priest | Prayer of Fortitude, Prayer of Spirit, Prayer of Shadow Protection |
| Druid | Gift of the Wild and Thorns (both, on everyone) |
| Mage | Arcane Brilliance |
| Warrior | Assigned shout (Battle Shout / Commanding Shout); alternating shouts by raid position until assigned |
| Death Knight | Horn of Winter |

Assignments, the button and bar positions and the bar options are stored in `RallyDB` (account-wide) and shared raid-wide over addon communication. Officers broadcast their edits; everyone receives them.

## PallyPower integration

The bundled `Sync.lua` bridges Rally and [PallyPower](https://www.wowace.com/projects/pally-power) users in the same raid, so both sides see the same paladin grid:

- Assignments made **in PallyPower** appear in your `/rally` window and drive your buff button.
- Assignments made **in Rally** (cell clicks, `/rally auto`, `/rally reset`) are re-broadcast as PallyPower messages.
- Rally announces itself as a paladin (with your Rally assignments as its blessings) and answers PallyPower's "announce yourselves" request.
- Warrior shouts have no PallyPower equivalent, so that part of a Rally grid stays local.

> [!NOTE]
> `Sync.lua` owns all of Rally's addon-message traffic: Rally's own protocol (paladin and warrior rows) plus the PallyPower bridge. It talks to Rally.lua through a small interface on the `Rally` table, runs a paced outgoing queue for both protocols, and stays silent while `/rally debug` is active. Deleting the file turns all syncing off — Rally keeps working locally (also for offline play).