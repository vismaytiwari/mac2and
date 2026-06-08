# Mac2And

Mac2And is a native macOS menu-bar clipboard bridge for Android. It watches the
Mac clipboard, serves the existing Android browser UI locally, and can expose it
through ngrok when the ngrok CLI is installed.

## Setup

1. Copy `.env.example` to `.env`.
2. Keep your existing values:

   ```sh
   NGROK_AUTHTOKEN=...
   APP_PASSWORD=...
   ```

3. Install the ngrok CLI if you want remote Android access. If it is not on
   `/opt/homebrew/bin/ngrok` or `/usr/local/bin/ngrok`, set `NGROK_BIN` in
   `.env`.

## Run

```sh
swift run Mac2And
```

The app appears in the Dock and the macOS menu bar. If ngrok starts successfully,
the Android URL is copied to the clipboard and a QR window opens. You can hide the
menu-bar icon via its menu ("Hide Menu Bar Icon"); reopen Mac2And (Dock or
Spotlight) to bring it back. Quit from the menu, the Dock, or the Force Quit window.

## Security

Mac2And exposes your Mac clipboard over a public ngrok URL and — when you opt
in — can type into whatever app is focused on your Mac. Understand the model
before exposing it to the internet.

- **Single shared secret.** Every page load and API call must present the app
  password as a bearer token, and the same secret derives the clipboard
  encryption key — so its strength is your security. Use a long, random value
  (`openssl rand -base64 24`); the app warns (log + notification) if it looks
  weak. With no password set, a random 128-bit token is used instead, but then
  the page cannot be opened remotely.
- **Change the password from the menu bar.** "Change Password…" rotates the
  secret (and the encryption key) at runtime and stores it in the macOS
  **Keychain** — no `.env` edit or rebuild needed. The old password stops
  working immediately, so this also acts as a global revoke. `APP_PASSWORD` in
  `.env` is only the bootstrap value until you set one in-app.
- **Manage connected devices.** The menu bar lists recently-connected devices
  (name from User-Agent + IP + last-seen) and lets you **Block for 1 hour** /
  **Unblock**; a blocked device gets `403` even with the right password.
  Blocking is keyed on a client-supplied device id, so it is a convenience for
  managing your own devices — to revoke an attacker, change the password.
- **Purge (panic button).** "Purge…" disconnects every device, clears the
  connection list and the failed-auth rate-limit state, and locks the app with a
  new **random** password you don't know — so nothing can reconnect until you
  set a known one via "Change Password…". Clipboard history is kept.
- **End-to-end encryption.** Clipboard text is sealed with AES-GCM (`CryptoBox`)
  before it crosses the tunnel, on top of ngrok's TLS. The local HTTP listener
  binds `127.0.0.1` only; the public surface is the ngrok URL.

- **Secrets are skipped.** The clipboard watcher ignores items marked
  concealed / transient / auto-generated (what password managers set), so copied
  passwords are never cached in history or synced.
- **Brute force is throttled.** Repeated bad tokens trigger a global lockout
  (HTTP 429) for a cooldown window. Requests arrive via the tunnel, so there is
  no trustworthy per-client IP and the limit is global — during a sustained
  attack legitimate requests are briefly locked out too.
- **Local secret hygiene.** `APP_PASSWORD` and `NGROK_AUTHTOKEN` live in `.env`
  (git-ignored); the generated `ngrok.yml` is written with `0600` permissions.

### Known limitations

- The clipboard key is `SHA256(password)` with no salt or KDF iterations, so a
  weak password is brute-forceable offline if ciphertext is captured. A strong
  password mitigates this; a future change could add a salted KDF (matched on
  the Android side).

## Build App Bundle

```sh
make app
open dist/Mac2And.app
```

## LaunchAgent

```sh
make install-agent
make uninstall-agent
```

The LaunchAgent points `MAC2AND_ENV_FILE` at this repo's `.env`, so your local
secret file is reused as-is and is not bundled into the app.

## Open Source Notes

- Licensed under the MIT License — see [`LICENSE`](LICENSE).
- `.env` is ignored and should stay local.
- `_electron_backup_*/` is ignored and contains the old Electron source backup.
- The Swift app does not depend on Electron, Node, npm, or bundled ngrok SDKs.
- Run `make check` before publishing.
