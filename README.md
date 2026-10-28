# Maple

A pen-and-paper workspace for iPad and Apple Pencil, where AI agents answer the marks you make on the page. Write a `?`, double-tap a spot, or draw an empty box, and Meta's Muse models reply in ink, in a small bubble, or by drawing inside the box.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event.

## Status

- [x] iPad project
- [x] Pencil-only canvas on a large sheet: two-finger pan and pinch, autosave a second after the pen pauses
- [x] Gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
echo 'MODEL_API_KEY = <your Meta Model API key>' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

The app reads the key from its Info.plist, so it ends up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.
