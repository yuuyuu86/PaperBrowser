# PaperBrowser

A tiny, secure WebKit browser for macOS — **~150 KB app**, one Swift file, zero dependencies.

## Features
Tabs (native macOS tabs), windows, private windows, address bar with search (DuckDuckGo), back/forward/reload, swipe gestures, find in page, zoom, full screen, print, downloads (to ~/Downloads), file upload, popups, JS dialogs, camera/mic with permission prompt, opening http(s) links from other apps.

## Lightweight by design
- Background tabs unused for 5 minutes are unloaded (restored when you switch back)
- On system memory pressure, all background tabs are unloaded immediately
- Built-in ad/tracker blocking (`Resources/blocklist.txt`, third-party requests only)

## Security
- App Sandbox + Hardened Runtime
- HTTPS-first: plain-HTTP pages are upgraded; insecure fallback only after explicit confirmation
- Lock / warning indicator (mixed content counts as not secure)
- Safe Browsing (fraudulent site warning) on
- Only http/https/about/blob/data load inside the browser; other schemes need confirmation
- No popups without a user gesture; camera/mic always prompt
- Private windows use a non-persistent data store; "Clear Browsing Data" menu item
- Web Inspector disabled; downloads are never auto-opened

## Build
```sh
./build.sh            # → build/PaperBrowser.app (ad-hoc signed)
SIGN_ID="Developer ID Application: …" ./build.sh
```
Requires macOS 14+, Xcode command line tools.
