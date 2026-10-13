# Fazon Nexus Tracker for mpv

An [mpv](https://mpv.io) script that logs what you watch to your [fazon.nexus](https://fazon.nexus)
**Track** as **active** or **passive immersion**, one hotkey each. The time goes into a
sub-category named after what you're watching (you can rename it first), created for you if you
don't have it yet.

- **Off by default.** Nothing is logged until you press a hotkey, so the English video you watch
  afterwards doesn't end up in your Track.
- **Counts real playing time:** not paused, seeking or buffering. It counts wall-clock time, so
  30 minutes at 1.5× speed logs 30 minutes.
- **One at a time:** active and passive can't run together; pressing the other hotkey switches.
- **Doesn't lose time:** it's sent every few minutes and when you stop or quit. If the site can't be
  reached, it's saved and sent the next time mpv starts.

Also available: [Fazon Nexus Tracker for VLC](https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker).

## Requirements

- **mpv 0.33 or newer.** Tested on Linux with mpv 0.37.
- **curl.** It's built into Windows 10 and 11 and macOS, and most Linux distributions have it
  (`curl --version` to check).
- A **fazon.nexus account** and a **Read & write API key**:
  1. Log in to [fazon.nexus](https://fazon.nexus) and open your profile (account menu →
     **Your profile**).
  2. Scroll down to **Developers** and create a key with **Read & write** access.
  3. Copy it (it's shown once). It looks like `fz_` followed by 43 characters.

## Install

1. Download [`fazon_track.lua`](https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker/releases/latest/download/fazon_track.lua)
   and [`fazon_track.conf`](https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker/releases/latest/download/fazon_track.conf)
   from the [latest release](https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker/releases/latest).
2. Put them in your mpv config folder (create the folders if they don't exist):

   | | mpv config folder | Script goes in | Settings go in |
   |---|---|---|---|
   | Linux, macOS | `~/.config/mpv/` | `scripts/fazon_track.lua` | `script-opts/fazon_track.conf` |
   | Windows | `%APPDATA%\mpv\` | `scripts\fazon_track.lua` | `script-opts\fazon_track.conf` |

   (On Windows, type `%APPDATA%\mpv` into the Explorer address bar. If you use a portable mpv with a
   `portable_config` folder next to `mpv.exe`, use that instead.)
3. Open `script-opts/fazon_track.conf` in a text editor and paste your key after `api_key=`:

   ```ini
   api_key=fz_your_key_here
   ```

4. Restart mpv.

On Linux or macOS from a terminal:

```sh
mkdir -p ~/.config/mpv/scripts ~/.config/mpv/script-opts
curl -L -o ~/.config/mpv/scripts/fazon_track.lua \
  https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker/releases/latest/download/fazon_track.lua
curl -L -o ~/.config/mpv/script-opts/fazon_track.conf \
  https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker/releases/latest/download/fazon_track.conf
chmod 600 ~/.config/mpv/script-opts/fazon_track.conf   # it will hold your key
```

## Use

| Key | |
|---|---|
| **Ctrl+a** | Track what's playing as **active immersion**. Press again to stop. |
| **Ctrl+p** | Track what's playing as **passive immersion**. Press again to stop. |

When you press one, mpv pauses and asks for the sub-category name, with the video's title filled
in. Press Enter to accept it (or edit it first); Esc cancels. You'll see
`Track: ● Active immersion › <name>` while it's on and how long you tracked when you stop.

- **Switching:** pressing the other hotkey stops the current one and starts the other, so time never
  counts twice.
- **Playlists:** when mpv moves to the next video, tracking carries on under the new video's title.
  Set `continue_on_next_file=no` to stop instead.
- **Where it goes:** the current Track week (Sunday 03:00 UTC to Sunday 03:00 UTC, like the site).
  If a week ends while you're watching, the time is split between the two weeks.

### How the name prompt appears

- **mpv 0.39 and newer:** a text box inside mpv.
- **Older mpv:** a small system dialog. On Linux that's `kdialog` (KDE) or `zenity` (GNOME and most
  others). macOS and Windows have one built in.
- **No dialog available,** or `prompt=no`: the suggested name is used as it is.

The suggestion is the video's title. Files without a title use the file name, with underscores
shown as spaces. To always suggest the same name (say, everything goes to *Anime*), set
`subcat=Anime`.

## Settings

All settings go in `script-opts/fazon_track.conf` (the release has a commented copy):

| Setting | Default | |
|---|---|---|
| `api_key` | *(empty)* | Your Read & write key. If it's empty, the `FAZON_API_KEY` environment variable is used. |
| `key_active` | `Ctrl+a` | Hotkey for active immersion. |
| `key_passive` | `Ctrl+p` | Hotkey for passive immersion. |
| `prompt` | `yes` | Ask for the sub-category name before tracking. |
| `subcat` | *(empty)* | Suggest this name instead of the video's title. |
| `continue_on_next_file` | `yes` | Keep tracking when the playlist moves on. |
| `flush_minutes` | `5` | How often to send time while tracking. |
| `api_url` | `https://api.fazon.nexus/v1/api/track` | Only change this if you run your own copy of the site. |

You can also bind the hotkeys in `input.conf` instead, which overrides `key_active`/`key_passive`:

```
Alt+i script-binding fazon_track/track-active
Alt+o script-binding fazon_track/track-passive
```

## What gets sent, and how it's counted

- Only what you track: the sub-category name and the time. Nothing about videos you don't track,
  and nothing else from your computer.
- Your key goes to `api.fazon.nexus` over HTTPS, and to curl on standard input, so it never shows up
  in the process list.
- **Hours are counted in hundredths (36 seconds)**, like the site. Each send adds whole 36-second
  steps and keeps the leftover seconds for next time. When you stop, the last leftover is rounded
  to the nearest step (18 seconds or more counts as 0.01 h). Your Track ends up within about
  18 seconds of your real watch time per session.
- Time is **added** to the sub-category's total for the week, never replacing what's there.

Unsent time is saved in mpv's state folder (`~/.local/state/mpv/fazon_track/` on Linux) and sent
the next time mpv starts.

## Good to know

- **Sub-category limit:** fazon.nexus allows **30 active sub-categories per category**. One per
  video fills that quickly. Archive old ones on the site (your hours stay in the old weeks), or set
  `subcat=` so everything goes to one name. When it's full you'll see an error and nothing is
  logged.
- **Names** are at most **40 characters**. Longer titles are cut.
- **Archived or renamed sub-categories:** if you archive or rename one on the site while tracking,
  the script creates it again and sends the time on the next try.

## Troubleshooting

Open mpv's console (`` ` ``) or run mpv from a terminal with `--msg-level=fazon_track=v`: the
script logs what it sends and why anything fails.

| Message | Fix |
|---|---|
| `no API key` | Put `api_key=fz_…` in `script-opts/fazon_track.conf` and restart mpv. |
| `401 … (check api_key …)` | The key is wrong or was revoked. Create a new one on your profile. |
| `403 … read-only` | The key is *Read only*. Create a *Read & write* one. |
| `409 … at most 30 active sub-categories` | Archive some sub-categories on the site. |
| `no response (is curl installed?)` | Install curl, or check your internet connection. |

**Platforms:** written for Linux, macOS and Windows, but only tested on Linux (KDE). If something
doesn't work on yours, please [open an issue](https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker/issues).

## Uninstall

Delete `scripts/fazon_track.lua` and `script-opts/fazon_track.conf`, and revoke the key on your
profile.

## Releasing

1. Bump `VERSION` at the top of `fazon_track.lua` and commit.
2. Tag and push: `git tag v1.0.1 && git push origin main v1.0.1`.

[`.github/workflows/release.yml`](.github/workflows/release.yml) checks the tag matches `VERSION`,
checks the script compiles, and publishes the release with `fazon_track.lua` and `fazon_track.conf`
attached. To redo an existing tag: *Actions → Release → Run workflow*.

## License

[MIT](LICENSE)
