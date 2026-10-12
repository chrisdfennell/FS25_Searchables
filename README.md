<p align="center">
  <img src="docs/images/icon.png" alt="Searchables icon" width="128">
</p>

<h1 align="center">Searchables</h1>

<p align="center">
  <b>Search as you type, right on the screen, in Farming Simulator 25.</b><br>
  Shop · Construction · Map (with Where's My Stuff built in)
</p>

---

FS25 has hundreds of vehicles, tools and buildings, and finding the one you want means scrolling through category after category. Searchables puts a search box right on the shop, construction and map screens. Click it, start typing, and the list narrows down as you type. There's no hotkey to remember and no pop-up.

![The shop search box under the balance, filtering a brand list](docs/images/shop-filter.png)

## Features

### 🛒 Shop
- **Filter any list as you type.** Open a category or a brand and type to narrow it down.
- **Search the whole shop.** On the category, brand, pack or DLC tiles, type two or more letters and every match in the shop appears in one list. Items with your words in their name come first.
- **Searches more than names:** brand, category, DLC, mod name and mod author.
- **Every word counts:** `fendt 700`, `john deere tedder` and `macdon pack` all work.
- **Filter by horsepower and price**, mixed in with words. See [Horsepower and price](#-horsepower-and-price) below.
- A match count shows in the box, for example `7 of 42`.

![Typing on the brand tiles searches the whole shop](docs/images/shop-global.png)

### 🐎 Horsepower and price
Type these in the shop search box, alone or together with words:

| You type | Finds |
|---|---|
| `hp>200`, `hp<300`, `hp>=250` | More / less horsepower than |
| `200-300hp` or `hp200-300` | Horsepower in a range |
| `250hp` | Exactly 250 hp |
| `$<50k`, `price>100000` | Cheaper / dearer than |
| `$100k-200k` | Price in a range |
| `$144500` or `$144,500` | That exact price |
| `fendt hp>300 $<400k` | Mix them: Fendts over 300 hp under $400,000 |

- Spaces are fine: `hp > 200`, `200 hp`, `$ 100k - 200k`.
- `k` means thousand and `m` means million. `€` and `£` work the same as `$`.
- A vehicle with several engine options matches if **any** of them fits, so a 200–300 hp tractor shows up for `hp>280`.
- The price is the shop's base price, before options.
- In store-wide results, a price filter sorts cheapest first and a horsepower filter sorts by horsepower.
- On the construction screen, price filters work too (buildings have no horsepower).

![Shop filtered with fendt hp>300 $<400k](docs/images/shop-hp-price.png)

### 🏗️ Construction
- Type to filter the buildings in **every category and tab** at once: `silo`, `greenhouse`, `fence`, `cow`.
- Add a price: `silo $<100k`.

![Construction screen filtered to silos](docs/images/construction.png)

### 🗺️ Map: Where's My Stuff
- Type in the box at the top of the map, or press **Ctrl+F**, to find **vehicles, bales, pallets, big bags, buildings and fields**.
- **Find vehicles by license plate.** `AB-123`, `ab 123` and `ab123` all find the same truck.
- Every match gets a **big arrow that shrinks down onto it**, so you can spot it at a glance. The nearest 40 get arrows; the rest get a marker dot (up to 500).
- Press **Enter** to centre the map on the nearest match.
- Search by fill type too: `wool`, `round bale`, `wheat`, `field 12`, `owned`.

![Map search with arrows on every match](docs/images/map.png)

## How to use it

| What you do | What happens |
|---|---|
| Click the search box | Start typing (menu hotkeys pause while you type) |
| Type | The list or map updates as you type |
| **Enter** or click elsewhere | Stop typing and keep the search |
| **Esc** | Clear the search |
| **Ctrl+F** on the map | Jump straight into the map search box |
| Go back, switch tabs or close the screen (shop/construction) | The search clears |

## Installation

1. Download `FS25_Searchables.zip`. Don't unzip it.
2. Put it in your mods folder:
   `Documents\My Games\FarmingSimulator2025\mods`
3. Start the game and tick **Searchables** in your savegame's mod list.

> **Upgrading from Where's My Stuff?** It's built into Searchables now. Remove `FS25_WheresMyStuff.zip` from your mods folder so the two don't run side by side. If the game warns that Where's My Stuff is missing when you load your savegame, that's safe to accept: it never saved anything to your savegame.

## Multiplayer

Supported. Everything runs on each player's own screen, so nobody else sees your searches or markers. Buying and placing still go through the game's normal purchase. Like any mod, everyone on the server needs it, and the game offers it for download when players join. On a dedicated server it loads without problems and simply does nothing there.

## Console commands

These are for when the developer console is enabled.

| Command | What it does |
|---|---|
| `wmsFind <text>` | The map search, listed nearest first |
| `wmsTarget <number>` | Set one of those results as your map target |
| `wmsSummary` | Totals of your pallets, big bags and bales per fill type |
| `wmsList <fillType>` | Every item of one fill type, and where it is |
| `wmsLeftovers` | Bales and pallets lying out on fields |
| `wmsShow <fillType\|ALL\|LEFTOVERS\|EMPTY>` | Mark items on the map |
| `wmsGoto <fillType\|ALL\|LEFTOVERS\|EMPTY>` | Mark items and target the nearest |
| `wmsHide` | Remove the map markers |
| `searchablesMove shop\|construction <dx> <dy>` | Nudge a search box by a few pixels |
| `searchablesDumpUi` | Print the open screen's layout (for troubleshooting) |

## FAQ

**Typing a letter opened another menu!**
Click into the box first. Menu hotkeys only pause while the box has a blinking cursor.

**I don't see a search box in the shop.**
It shows on the shop's item lists and on the category, brand, pack and DLC tiles. Shop pages that don't list items have no box.

**Does it work with mod vehicles and mod buildings?**
Yes. Anything in the shop or construction menu can be searched, and you can search by the mod's name or author too.

**Can I search by horsepower or price?**
Yes, in the shop and (price only) on the construction screen: `hp>200`, `$100k-200k`, `$144,500`. See [Horsepower and price](#-horsepower-and-price).

**My horsepower search missed a tractor.**
Horsepower comes from each vehicle's own file. Searchables reads those in the background during your first minute or so in the game. A horsepower search made before then still works, but may pause briefly the first time. Mod vehicles that don't list their horsepower can't be found by `hp`.

## For modders

- **Shop:** `ShopItemsFrame.setDisplayItems` is wrapped, so every list the game shows passes through the filter, including refreshes. Store-wide results are shown in the shop's own item list. Buying works exactly as it does from a category.
- **Construction:** after `ConstructionScreen:rebuildData` the full `items[category][tab]` lists are set aside, and the screen gets filtered copies.
- **Map:** `IngameMapElement.update` and `draw` are wrapped to show the box and the arrows.
- **Why everything hooks `update`:** a screen's `onOpen`, `onClose` and `onPageChange` callbacks are bound when the game loads its UI, before any mod, so hooking them does nothing. `update` is called on the screen directly.
- **Menu buttons while typing:** while a box has the cursor, menu button registration is held back and replayed when typing ends. Otherwise the buttons would land in the text input's input context and stop working.

Source layout:

```
scripts/Searchables.lua              shared matching, console commands, lifecycle
scripts/SearchablesSearchBox.lua     the search box element
scripts/SearchablesShop.lua          shop hooks
scripts/SearchablesConstruction.lua  construction hooks
scripts/WheresMyStuff*.lua           map search, scanning, markers
gui/                                 box layout and profiles
```

## Credits

Made by **Fennell**. Where's My Stuff by Fennell, now part of Searchables.
