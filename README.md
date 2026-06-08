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

The app appears in the macOS menu bar. If ngrok starts successfully, the Android
URL is copied to the clipboard and a QR window opens.

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

- `.env` is ignored and should stay local.
- `_electron_backup_*/` is ignored and contains the old Electron source backup.
- The Swift app does not depend on Electron, Node, npm, or bundled ngrok SDKs.
- Run `make check` before publishing.
