# Rally

*Raid buff assignments for all classes — PallyPower-style, but simple*

![WoW WotLK 3.3.5a](https://img.shields.io/badge/WoW-Wrath%20of%20the%20Lich%20King%203.3.5a-9b1c1c?style=flat-square)
![Version](https://img.shields.io/badge/version-1.0-blue?style=flat-square)

[Features](#features) • [Installation](#installation) • [Usage](#usage) • [How buffing works](#how-buffing-works)

A lightweight buff-assignment and one-button buffing addon for World of Warcraft: Wrath of the Lich King (3.3.5a). Plan the paladin blessings in a compact grid, sync them across the raid, then single left-click to buff — Rally walks the raid, finds whoever is missing an assigned buff, and casts it. When everyone is buffed, the button hides itself.

## Features

- 🎯 **One-button buffing** — casts the next missing buff, listing out-of-range raiders above the button until they come in range
- 🛡️ **Paladins only need planning** — a grid of blessings per target class; every other buffer class casts its standard buff automatically, no assignment needed
- 🔄 **Live raid sync** — assignments broadcast over addon messages; only the raid leader or an assistant can edit them
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
| `/rally auto` | Auto-assign a sensible blessing to every paladin (leader/assistant only) |
| `/rally reset` | Clear all assignments |
| `/rally debug` | Preview the window and cast button with a fake raid |

> [!TIP]
> Run `/rally debug` anywhere — even solo in a city — to try the full UI. It uses a throwaway fake raid and never touches your real assignments.

### The cast button

A single secure button appears when someone is missing a buff:

- **Left-click** — cast the next missing buff (greater version first, lesser fallback without reagents)
- **Right-click** — toggle the assignment window
- **Shift-drag** — move the button (position is remembered)

The missing-buffs list above the button shows who still needs what, and it disappears once everyone is buffed. During combat the button can't change spells, but it updates again as soon as combat ends.

### The assignment window

One row per paladin, one column per target class:

- **Click** a cell — cycle to the next blessing
- **Shift-click** — set the whole row at once
- **Right-click** — cycle to the previous blessing
- **Hover** — tooltip showing the exact spells the cell casts

## How buffing works

Paladins are assigned through the window. Everyone else needs no planning — their standard buff is presumed:

| Class | Casts |
|---|---|
| Paladin | Assigned blessings (Kings / Might / Wisdom / Sanctuary) |
| Priest | Prayer of Fortitude, Prayer of Spirit, Prayer of Shadow Protection |
| Druid | Gift of the Wild |
| Mage | Arcane Brilliance |
| Warrior | Battle Shout or Commanding Shout (alternating by position in the raid) |
| Death Knight | Horn of Winter |

Assignments are stored in `RallyDB` (account-wide) and shared raid-wide over addon communication. Officers broadcast their edits; everyone receives them.