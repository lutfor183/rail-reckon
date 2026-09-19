# Seat monitor

Personal seat-availability watcher for a train booking site.
Polls the search API and alarms when seats open up. Termux and Linux.

## What it does

- Watches chosen trains and seat classes on one route and date.
- Two data sources: a public mirror (no login) or the direct API
  using your own session headers.
- Alerts with sound, Android vibration/notification, or desktop notify.
- All settings stay local (`~/railway-monitor.json`, mode 600).

## Start

1. Install deps: `pkg install curl jq` (Termux) or
   `sudo apt install curl jq` (Linux).
2. Run `./rail.sh`, pick mode 1 (no login) or 2 (paste session JSON).
3. Mode 2 on Android Chrome without extensions: see
   `rail-bookmarklet.js` — bookmark it, arm it, tap search on the
   booking page, paste the shown JSON into the script, type `END`.
4. Pick trains and classes, leave it running. Ctrl+C stops.

## Notes

- Personal and educational use. You run it, so you follow the
  booking site's terms and rate limits (minimum interval is
  enforced in the script).
- No passwords are stored or asked for — only a copy of your own
  browser session headers, kept in your home directory.
- Provided as-is, no warranty. The author is not responsible for
  misuse, account action, or missed seats.

## Public encrypted copy

The `pub` branch holds only ciphertext (`reckon.tar.age`) plus docs —
no login needed to clone it anywhere, search finds nothing readable.
Decrypt with the passphrase (typed, never stored):

  age -d reckon.tar.age | tar xz
  ./rail.sh

Install age: `pkg install age` / `sudo apt install age`.
Maintainer rebuilds it with `./release.sh` (prompts passphrase).
