# Maple

A pen-and-paper workspace for iPad and Apple Pencil, where AI agents answer the marks you make on the page. Write a `?`, double-tap a spot, or draw an empty box, and Meta's Muse models reply in ink, in a small bubble, or by drawing inside the box.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event.

## Status

- [x] iPad project
- [x] Pencil-only canvas on a large sheet: two-finger pan and pinch, autosave a second after the pen pauses
- [x] Gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete
- [x] Two-finger tap undo, three-finger tap redo, Pencil double-tap swaps pen and eraser
- [x] Muse Spark 1.3 client (Responses API: text and PNG input, low reasoning effort by default)
- [ ] Marks: `?`, double dot and empty box wake an agent
- [ ] Answers: quiet dots that open into bubbles, nudge and hint before the answer
- [ ] Agent ink: drawings and graphs inside a box
- [ ] SAM 3.1 for circled regions; multi-agent shared memory

## Meta models

| Model | Used for |
|---|---|
| `muse-spark-1.3` | Reading the page and the mark, answering, drawing |

## Checks

They run on the Mac, without the simulator.

```sh
swiftc -swift-version 6 -parse-as-library Maple/Grouping.swift checks/grouping-check.swift -o /tmp/grouping-check && /tmp/grouping-check
swiftc -swift-version 6 -parse-as-library Maple/Muse.swift Maple/Agent.swift checks/muse-check.swift -o /tmp/muse-check
MODEL_API_KEY=... /tmp/muse-check   # parses a recorded reply, then 4 live calls: reading a PNG, a ?, plain writing, a double dot
```

28 Oct, low effort: reading "2 + 2 = ?" took 1.9–2.3 s and about 100–200 output tokens (at the API's default high effort, "say hi" took 678). The agent read "x² = 49 ?" as a question with a nudge, a hint and "x = 7 or x = -7" in 2.6 s, left plain writing alone in 2.3 s, and explained a double-dotted word in 3.9 s.

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
echo 'MODEL_API_KEY = <your Meta Model API key>' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

The app reads the key from its Info.plist, so it ends up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.
