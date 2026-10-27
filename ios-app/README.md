# YT Music for iOS (native app)

A native iPhone app that wraps the web UI in `../frontend` with [Capacitor](https://capacitorjs.com). The UI is bundled
inside the app, so it opens instantly and saved songs play with no connection.

**Music comes from the phone itself.** The app talks to YouTube Music directly through the on-device engine in
`frontend/js/engine`, so it needs no PC, no VPN and no access token. A server is optional (see below).

You don't need a Mac: a cloud Mac (GitHub Actions) builds the app.

## Build

1. Push this repository to your GitHub account (private is fine). `backend/token.txt`, the Python environment, logs and
   anything signing-related are already excluded by `.gitignore`.
2. Open **Actions → Build iOS app → Run workflow**. It takes about a minute.
3. Download the artifact **`YTMusic-unsigned.ipa`** from the finished run.

The workflow also accepts a **Bundle ID** input (default `com.ytmusic.app`).

## Install

The build is unsigned, so you sign it with your own certificate on the iPhone, using the signing tool you normally use
for your own apps. Then trust the developer: *Settings → General → VPN & Device Management → (developer) → Trust*.

Open the app. There is nothing to set up: it searches and plays on its own.

### Optional: have the cloud build sign the IPA

Add three repository secrets (*Settings → Secrets and variables → Actions*), then run the workflow again. It then also
produces `YTMusic-signed.ipa`.

| Secret | Value |
|---|---|
| `IOS_CERT_P12_BASE64` | the `.p12` certificate (with private key), base64 |
| `IOS_CERT_PASSWORD` | the password of that `.p12` |
| `IOS_PROFILE_BASE64` | the `.mobileprovision` file, base64 |

Encode the two files first (PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificate.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("profile.mobileprovision")) | Set-Clipboard
```

Don't paste these anywhere else, and never commit the files themselves. If your provisioning profile names one exact
bundle ID, the build uses it; if it is a wildcard, the build uses the "Bundle ID" input.

## How the on-device engine works

- `frontend/js/engine/engine.js` implements the same endpoints as the Python server (search, home, explore, charts, moods,
  albums, artists, playlists, radio, genres, synced lyrics, stream addresses) with the `youtubei.js` client
  (`frontend/vendor/youtubei.js`, MIT). The interface can't tell the difference.
- **Audio:** the phone asks YouTube for a stream address with the visionOS client, which serves full-length audio with any
  range request, so the player streams it directly. Each address is checked with a tiny range request before it is used. The
  iOS and Android-VR clients only serve the first minute, so they are a last resort.
- **Network:** inside the app the engine uses its own native HTTPS client (`ios-app/native/Ipv4Http.swift`, added to the
  project by `scripts/patch_ios.py`). It always uses **IPv4**, opens a fresh connection per request and keeps no cookies or
  cache, because iOS otherwise picks IPv4 or IPv6 per connection and YouTube treats them differently. If it is unavailable the
  engine falls back to Capacitor's HTTP (fresh session per request, cookies wiped).
- **Playback modes:** Settings → Playback offers Auto, Stream, or Download first (with next-song prefetch).
- **When YouTube changes something:** if you also run the optional server and set its address, the app loads the engine
  from the server (falling back to its bundled copy), so a fix is a file update there. Otherwise rebuild the app.
- **Tests:** the engine also runs in Node, so each endpoint can be compared with the Python server's output.

## What the app does differently from the website

- No PC needed to search and play. It opens offline too: the interface and your saved songs work, and Home and Explore show
  the last loaded data.
- Real background and lock-screen audio (the build turns on the iOS audio background mode).
- No browser chrome, so the layout fills the screen.
- Certificates from third-party or enterprise signers can be revoked. If the app stops opening, rebuild and sign with a new
  one. **Settings → Privacy → Back up and restore** keeps your data safe.

## Optional server

`backend/` holds a FastAPI server that serves the same UI as a website and can cut ringtone clips with ffmpeg. In the app,
**Settings → About → Music source** can switch to your server, or you can add a server address only for ringtone clips.
`ios-app/scripts/make_ota.py` can write an over-the-air install page for a signed IPA into `backend/ota/` if you prefer
installing from a link.

## Files

- `capacitor.config.json`: app name, bundle ID placeholder, status bar
- `scripts/copy-web.mjs`: copies `../frontend` into `www/` for bundling
- `scripts/patch_ios.py`: Info.plist (background audio, portrait), audio session, the IPv4 client, icon, dark launch screen
- `native/Ipv4Http.swift`: the IPv4-only HTTPS client plugin
- `scripts/make_ota.py`: writes an install page for a signed IPA into `backend/ota/`
- `../.github/workflows/ios.yml`: the cloud build (and optional signing)
