# Omarchy Bar Manager

![Bar Manager](images/preview.png)

One panel to control which plugins appear in your [Omarchy](https://omarchy.org) bar, so you don't have to hand-edit `shell.json` or run a string of `omarchy plugin ...` commands every time you want to change something.

For every bar plugin you get:

| Action | What it does |
|---|---|
| **Hide / Show** | Take a widget off the bar but **keep it installed and enabled**, then put it back in the same spot later. |
| **Enable / Disable** | Turn a plugin on or off. |
| **Update** | Update a git-installed plugin (or **Update all** from the header). |
| **Uninstall** | Remove a plugin entirely. Needs a second click to confirm. |

Built-in Omarchy plugins can be hidden, shown, enabled and disabled; update and uninstall are only offered for plugins you installed.

## Why

Omarchy's CLI can enable, disable and remove plugins, but has no "take it off the bar, but keep it" command, and widgets can live in different places (a bar section, or hosted inside a tray plugin). This tool handles both, shows what is actually on your bar right now, and does it from a clickable list.

## Features

- **Live status** for every bar widget: `[x]` on the bar (and which section, or `@tray`), `[ ]` not on it, plus enabled/disabled and built-in markers.
- **Hide without uninstalling**, with the original position remembered so **Show** restores it.
- **Smart search**: finds plugins by name, id, category, aliases and description, understands everyday words (`sound` finds Audio, `wifi` finds Network, `cpu` finds System monitor) and tolerates small typos (`blutooth`).
- **Duplicate cleanup**: removes repeated tray entries that cause doubled icons, automatically on every change (or `barctl fix`).
- **Safe edits**: before every change to `shell.json` a backup is saved as `shell.json.bak.barctl-<timestamp>` (last five are kept).
- **Theme-aware**: simple flat, monospace look that follows your current Omarchy theme colors.
- **Every bar**: works with the main bar and with [Extra Bars](https://github.com/s3pp3ku/omarchy-extra-bars). Each row has pickers for the bars (T B L R) and the section (‹ · ›), for installed or not-yet-shown plugins alike. The bar letters are toggles: click each bar you want, so one plugin can sit on several bars at once. For the Tray plugin the main bar gets the real Tray and every other bar gets one of its own built-in trays. Removing an extra bar remembers its widgets, so adding it back restores them. Moving the main bar to an edge that already has a bar swaps the two, so nothing is lost.
- **Service widgets placed correctly**: widgets that ship a background service (e.g. Keylight) are put directly on a bar, never inside the tray, where they would be invisible.
- **Trays**: `+ Tray` adds a new empty tray (any number, on any extra bar). The `▢` button on each row puts a widget into a tray and cycles through them; trays move between bars and sections with the same pickers.
- **Side bars**: a side bar's sections are top, middle and bottom (the panel shows ↑ · ↓ for them). Extra-bars supports dragging widgets between sections and bars.
- **Scriptable**: everything the panel does is available from the terminal via `bin/barctl`.

## Requirements

- Omarchy with the shell plugin system (`omarchy plugin`, `omarchy-shell`)
- `jq`

## Install

```sh
omarchy plugin add https://github.com/s3pp3ku/omarchy-bar-manager.git --enable --yes
```

Enabling it adds a small sliders icon to the right side of your bar. Click it to open the manager, or bind a key:

```sh
omarchy-shell shell toggle s3pp3ku.bar-manager '{}'
```

Press **Esc** to close the panel.

To remove it:

```sh
omarchy plugin remove s3pp3ku.bar-manager --yes
```

## Command line

```sh
bin/barctl list                  # JSON of every bar widget and its state
bin/barctl hide <plugin-id>      # off the bar, still installed
bin/barctl show <plugin-id>      # back on the bar where it was
bin/barctl enable <plugin-id>
bin/barctl disable <plugin-id>   # also takes it off the bar
bin/barctl update <plugin-id>    # or: update --all
bin/barctl uninstall <plugin-id>
bin/barctl place <plugin-id> <top|bottom|left|right> [left|center|right]
bin/barctl togglebar <top|bottom|left|right>   # add/remove an empty extra bar
bin/barctl mainpos <top|bottom|left|right>     # move the main bar (an extra bar there swaps places)
bin/barctl swapbars <edge> <edge>              # swap any two bars (main or extra) between edges, widgets stay with their bar
bin/barctl addtray <edge|auto> [section]        # new empty tray on an extra bar
bin/barctl intray <plugin-id> <tray-id>        # put a widget in a tray (place takes it back out)
bin/barctl rmtray <tray-id>                    # remove a tray; its widgets stay on the bar
bin/barctl drop <plugin-id> <edge> <section> [before-id]   # what drag and drop uses; side bars accept top/middle/bottom
bin/barctl toggle <plugin-id> <edge> [section]   # add it to / remove it from one bar, others untouched
bin/barctl setsection <plugin-id> <section>    # same section on every bar it is on
bin/barctl fix                   # drop duplicate tray entries
```

Use `OMARCHY_SHELL_JSON=/path/to/copy.json` to try changes against a copy of your config instead of the real one.

## How it works

`barctl` is a small bash + `jq` script over the real Omarchy commands and `~/.config/omarchy/shell.json`. Top-level bar widgets are removed from `bar.layout`; widgets hosted inside a tray plugin are removed from that tray's widget list. Where each hidden widget lived is stored in `~/.local/state/barctl-hidden.json` so **Show** can put it back. The panel (`Panel.qml`) is only a front end that calls `barctl`.

## Notes

- The compositor may size the window narrower than requested; the layout is built for roughly 560px and up.
- Tested on Omarchy with a tray plugin hosting several widgets; layouts with other container plugins may behave differently. Issues and pull requests welcome.

## License

MIT

## Settings are remembered

Taking a plugin off the main bar remembers its entry (the Tray's widget list, a clock's format and so on) in `~/.local/state/barctl-removed-main-entries.json`, and putting it back restores it.
