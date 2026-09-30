# Ostgotapendeln Next Train

Noctalia plugin (`emil/ostgotapendeln_next_train`) showing the next train
departure between two configurable stops on Ostgotapendeln, using the
[Trafiklab Realtime APIs](https://www.trafiklab.se/api/our-apis/trafiklab-realtime-apis/).

## Install

```sh
mkdir -p "$XDG_DATA_HOME/noctalia/plugins"
git clone https://github.com/dunderrrrrr/noctalia-ostgotapendel \
  "$XDG_DATA_HOME/noctalia/plugins/ostgotapendeln_next_train"
```

(`$XDG_DATA_HOME` is usually `~/.local/share`.) Enable the plugin in
Noctalia's settings; `.luau` edits hot-reload, `plugin.toml` edits need a
full config reload.

### NixOS / home-manager

Using home-manager's `home.file`:

```nix
{ pkgs, ... }:
let
  ostgotapendeln-next-train = pkgs.fetchFromGitHub {
    owner = "dunderrrrrr";
    repo = "noctalia-ostgotapendel";
    rev = "main";
    hash = pkgs.lib.fakeHash; # replace with the real hash on first build
  };
in
{
  xdg.dataFile."noctalia/plugins/ostgotapendeln_next_train".source =
    ostgotapendeln-next-train;
}
```

Nix will print the correct hash on a failed build if `fakeHash` is left in
place; swap it in and rebuild. Since the store path is read-only, `.luau`
hot-reload won't pick up local edits — rebuild `home-manager switch` to
apply plugin updates instead.

## Setup

1. Get a free API key at [trafiklab.se](https://www.trafiklab.se/api/our-apis/trafiklab-realtime-apis/)
   (create a project, add "Trafiklab Realtime APIs").
2. Add the `bar` widget (`emil/ostgotapendeln_next_train:bar`) from the
   Add-widget picker.
3. Paste the API key into the widget's **Trafiklab API key** setting.
4. Set **Origin stop name** / **Destination stop name** to any two stops on
   the same line.

## How it works

The service resolves both stop names to Trafiklab stop ids once (cached),
then polls Timetables departures from the origin on the configured interval
(default 30s). If the destination is an intermediate stop rather than a
train's final destination, the Timetables endpoint alone can't tell whether
a given departure passes through it, so the service also checks each
candidate departure's Trip Details to confirm it actually calls at the
destination stop (also cached).

## Bar widget

Shows a train glyph and minutes until the next confirmed departure (e.g.
`12 min`, or `now`). Hover for a tooltip with the next few departures
(time, platform, line, delay, destination). Click to force a refresh, or
turn off **Show countdown** to show just the icon.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_countdown` (widget) | `bool` | `true` | Show minutes-until text in the bar. |
| `api_key` (service) | `string` | `""` | Trafiklab Realtime APIs key. |
| `origin_name` (service) | `string` | `""` | Stop to show departures from. |
| `destination_name` (service) | `string` | `""` | Stop the train must call at. |
| `poll_seconds` (service) | `int` | `30` | Poll interval in seconds (15-300). |

## IPC

```sh
noctalia msg plugin emil/ostgotapendeln_next_train:service all refresh
```
