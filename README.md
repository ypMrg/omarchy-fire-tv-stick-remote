# Fire TV Remote for Omarchy

Control an Amazon Fire TV Stick from the Omarchy Quattro bar with the mouse or
keyboard. The plugin uses network ADB and includes shortcuts for Netflix, Prime
Video, Disney+, and YouTube.

## Install

```bash
omarchy plugin add https://github.com/ypMrg/omarchy-fire-tv-stick-remote.git --enable
```

The first launch creates an isolated Python environment and installs
`adb-shell==0.4.4`.

Update or remove the plugin with:

```bash
omarchy plugin update io.github.ypmrg.fire-tv-remote
omarchy plugin remove io.github.ypmrg.fire-tv-remote
```

## Setup

1. On the Fire TV, open **Settings → My Fire TV → About**.
2. Press **Select** seven times on the device name to unlock developer mode.
3. Open **Developer options** and enable **ADB debugging**.
4. Open the Fire TV widget, then select **Devices**.
5. The plugin scans automatically. Select **Connect Host**, accept the
   **Allow USB debugging** prompt on the TV, then retry if requested.

Discovery first parses:

```bash
avahi-browse -rtpk _amzn-wplay._tcp
```

It extracts the Fire TV name and IPv4 address from the mDNS response. ADB mDNS
and a bounded scan of port `5555` are used as fallbacks.

If discovery finds nothing, enter the IPv4 address shown under
**Settings → My Fire TV → About → Network**. Port `5555` is used by default.

## Controls

| Key | Action |
| --- | --- |
| Arrows / H J K L | Navigate |
| Enter | Select / OK |
| B | Back |
| G | Home |
| M | Menu |
| P | Play / pause |
| − / + | Volume |
| W / S | Wake / sleep |
| 1 / 2 / 3 / 4 | Netflix / Prime Video / Disney+ / YouTube |
| D | Devices |
| Esc / Q | Close |

## Requirements

- Omarchy Quattro
- Python 3.9+ with `venv`
- Fire TV and computer on the same LAN
- ADB debugging enabled on the Fire TV
- `avahi-browse` recommended for immediate discovery

## Credits

This plugin is **adapted almost entirely** from the Omarchy bar-widget and
session design by **Thomas Evans**:

| | |
| --- | --- |
| Author | [Thomas Evans](https://github.com/teevans) (`teevans`) |
| Apple TV original | **[omarchy-apple-tv-remote](https://github.com/teevans/omarchy-apple-tv-remote)** |
| License | MIT |

**Have an Apple TV?** Use his plugin — it is the original implementation for
Apple TV. This repository adapts that design for Fire TV Stick over network ADB.

## License

[MIT](LICENSE) — Copyright (c) 2026 Matthieu G.C.

The logos in `assets/` remain trademarks of their owners; see
[assets/README.md](assets/README.md).
