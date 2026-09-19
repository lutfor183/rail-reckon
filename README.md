# Seat monitor (public copy)

Personal seat-availability watcher for a train booking site.
This branch holds only ciphertext plus docs.

## Use (any device, no login)

1. Clone: `git clone --branch pub --depth 1 https://github.com/lutfor183/rail-reckon.git`
2. Install age: `pkg install age` / `sudo apt install age`.
3. Decrypt (passphrase typed, never stored): `age -d reckon.tar.age | tar xz`
4. Run `./rail.sh`. Deps: `curl jq`.

Session export without extensions: see `rail-bookmarklet.txt`
(paste into a bookmark URL, arm it, tap search, copy the JSON).

## Notes

Personal, educational use. You operate it; follow the booking
site's terms and rate limits. No passwords stored — only your own
browser session headers in your home dir. As-is, no warranty;
the author is not responsible for misuse or missed seats.
