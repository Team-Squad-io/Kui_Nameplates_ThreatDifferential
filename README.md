# ThreatDifferential (Kui Nameplates Module)

A KuiNameplates module for **Wrath of the Lich King (3.3.5)** clients that displays your threat as both a **percentage** and a **differential vs. the next highest player** directly on enemy nameplates.

## ✨ Features

- Threat % display above enemy nameplates
- **Lead / deficit vs. next highest threat** (e.g. `+12k` or `-8k`)
- Configurable modes:
  - **My % only**
  - **Lead vs next only**
  - **Both: % and lead**
- Text colour matches Kui TankMode colours (green/orange/red)
- Fade overrides:
  - Losing threat (orange)
  - Red only
  - Threshold %
  - Sticky “recently lost aggro”
  - Off-targets only
  - Elite / Boss priority
  - Smart TankMode
- Position, scale, and out-of-combat toggles
- Optional **force-show** when any unit changes target (e.g. a mob switches to another player)
- Clears all text automatically when leaving combat (avoids stale PvP values)

## 📦 Installation

1. Download the latest release or clone this repo.
2. Rename the top-level folder to:
     Kui_Nameplates_ThreatDifferential
3. Place it inside your WoW addons directory, for example:
     World of Warcraft\Interface\AddOns\ThreatDifferential
4. Ensure you have Kui Nameplates installed and enabled.
5. Restart WoW

## ⚙️ Configuration

Options available:
- **Enable / Disable**
- **Enable out of combat**
- **Display mode**: % / lead / both
- **Colour settings**: match Kui glow colours
- **Fade override modes**
- **Always show target**
- **X/Y offsets and scale**
- **Force-show on target change** duration
- **Update rate** and stale timeout

Changes take effect immediately or after a `/reload`.

## 🐞 Notes
- Threat data is limited by the WoW API: you only get **detailed values** for your `target`, `mouseover`, and `focus`. The module works around this by caching and refreshing on relevant events.
- Works with Wrath private servers (3.3.5a / build 12340) as long as the API matches retail-era behaviour.

## 🙏 Credits
- Built on [Kui Nameplates](https://www.curseforge.com/wow/addons/kuinameplates) by Kesava.  
- ThreatDifferential module by *Shiftard - Kezan*.