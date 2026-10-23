ProfessionBar
=============
Version 1.0.2 | Author: ßellena - Blade's Edge
Updated for errors Blizzard caused in their latest patch 12.1.5


Version 1.0.0 | Author: ßellena - Blade's Edge

A dynamic button bar that displays icons for all of your learned professions
and sub-abilities. Hover over a profession icon to reveal a popup row of
related sub-spells, tools, toys, and items you own.


Features
--------
- Automatically detects all learned professions (primary and secondary)
- Shows sub-abilities for each profession (e.g. Smelting, Milling, Prospecting)
- Optional tools mode: shows profession-related toys, items, and battle pets
  you own in your popup (e.g. Jeeves, Blingtrons, wormhole generators)
- Spec-locked items (e.g. Gnomish/Goblin Engineer transporters) only appear
  if you have the required specialization
- Popup rows wrap automatically up to 8 icons wide
- Mini restore button ("PB") always visible, even when the main bar is hidden
- All buttons are fully click-through secure and combat-safe
- Popup sub-menus are suppressed during combat to avoid Blizzard taint errors
- Positions saved between sessions, shared across all characters


Installation
------------
1. Download ProfessionBar.zip
2. Extract into your AddOns folder:
   World of Warcraft/_retail_/Interface/AddOns/
   The result should be:
   Interface/AddOns/ProfessionBar/ProfessionBar.lua
   Interface/AddOns/ProfessionBar/ProfessionBar.toc
3. Log in and enable ProfessionBar in the AddOns list on the character screen


Usage
-----
The bar appears automatically on login showing all your learned professions.

Hover over any profession icon to see its sub-abilities and owned tools
in a popup above it.

The small "PB" button is always visible and can be dragged anywhere:
  Left-click  = show or hide the main bar
  Right-click = toggle tools/items mode on or off
  Drag        = reposition the mini button

Both the main bar and the mini button can be freely dragged to reposition them.


Slash Commands
--------------
/profbar or /pb                 Toggle the main bar on or off
/profbar reset  or  /pb reset   Reset both the bar and mini button to center screen
/profbar tools  or  /pb tools   Toggle tools/items mode on or off


Tools Mode
----------
When tools mode is enabled (right-click the PB button, or /pb tools), each
profession popup will include a second row of profession-related items, toys,
and battle pets that you own. Examples:

  Engineering  Blingtrons, wormhole generators, Jeeves, MOLL-E, Loot-A-Rang
  Fishing      Anglers Fishing Raft, Nat's Fishing Chair, fishing poles
  Cooking      Chef's Hat
  Alchemy      Portable Alchemist's Lab
  Blacksmithing  Khaz'gorian Hammer, Thermal Anvil
  Inscription  Scroll of Recall

Items are only shown if you actually own them. Spec-locked items (such as
Gnomish or Goblin transporter toys) only appear if you have the right
Engineering specialization.


Notes
-----
- The bar rebuilds automatically when your professions change or you change zones
- If a profession button shows a question mark icon, the spell data was not
  available at load time. It will resolve on the next zone change or /reload
- During combat, sub-menus will not open and the bar cannot be shown or hidden.
  This is intentional to comply with Blizzard's combat lockdown restrictions.
- If you add or remove a profession mid-session, the bar updates automatically


Saved Variables
---------------
ProfessionBarDB (global, shared across all characters)
  Stores bar position, mini button position, hidden state, and tools mode setting.


Support
-------
https://www.curseforge.com/wow/addons/professionbar