# The iPhone app

A SwiftUI app (iOS 16+). The YouTube engine is JavaScript (`Engine/`); the app runs it in a hidden web view and talks to it through a small bridge.

## Build

Builds run on GitHub's Macs: **Actions → Build iOS app → Run workflow**. The result is an unsigned `YTMusic-unsigned.ipa` (no secrets needed). See the main README for how to install it.

Locally you need a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate             # makes YTMusic.xcodeproj from project.yml
open YTMusic.xcodeproj
```

## Layout

| File | What it does |
|---|---|
| `Sources/App.swift` | App entry, tabs, theme and accent, the mini player, shared sheets |
| `Sources/EngineHost.swift` | The hidden web view that runs the engine, and the bridge for its network calls |
| `Sources/V4Client.swift` | The IPv4-only HTTPS client the engine's requests go through |
| `Sources/PlayerModel.swift` | Playback (AVPlayer), queue, radio, lyrics, sleep timer, downloads, lock screen |
| `Sources/Library.swift` | Likes, history, playlists, saved items and stats, kept in one JSON file; backup import and export |
| `Sources/Downloads.swift` | Songs saved for offline listening |
| `Sources/M4ATagger.swift` | Writes title, artist, album and cover into exported `.m4a` files |
| `Sources/*View.swift` | The screens |
| `Engine/host.html`, `host.js` | The page the engine runs in |
| `Engine/js/engine/` | The engine: search, home, charts, albums, artists, lyrics, radio and stream addresses |
| `Engine/vendor/` | `youtubei.js` (MIT) |

## Notes

- The bundle id is `com.ytmusic.swiftui`. Installing a new build over an old one keeps your data.
