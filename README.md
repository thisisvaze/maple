# Maple

A pen-and-paper workspace for iPad and Apple Pencil, where AI agents answer the marks you make on the page. Write a `?`, double-tap a spot, or draw an empty box, and Meta's Muse models reply in ink, in a small bubble, or by drawing inside the box.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event.

## Status

- [x] iPad project
- [x] Pencil-only canvas on a large sheet: two-finger pan and pinch, autosave a second after the pen pauses
- [x] Gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete
- [x] Two-finger tap undo, three-finger tap redo, Pencil double-tap swaps pen and eraser
- [x] Muse Spark 1.3 client (Responses API: text and PNG input, low reasoning effort by default)
- [x] Marks: a `?` or a double dot wakes the agent 0.6 s after the pen rests
- [x] Answers: quiet dots that open into glass bubbles; a `?` opens a nudge, then a hint, then the answer; saved with the page
- [x] App icon: a pencil scribble that straightens into a glowing arrow, a rough thought the AI turns into a direction
- [x] Empty box: Muse draws in it with the agent's blue pen: a line drawing with pen-font labels, or a graph the app plots itself; one undo takes it away
- [ ] Shared memory the agents read and propose changes to

## Meta models

| Model | Used for |
|---|---|
| `muse-spark-1.3` | Reading the page and the mark, answering, drawing |

## Checks

They run on the Mac, without the simulator.

```sh
swiftc -swift-version 6 -parse-as-library Maple/Grouping.swift checks/grouping-check.swift -o /tmp/grouping-check && /tmp/grouping-check
swiftc -swift-version 6 -parse-as-library Maple/Drawing.swift Maple/Hershey.swift checks/drawing-check.swift -o /tmp/drawing-check && /tmp/drawing-check
swiftc -swift-version 6 -parse-as-library Maple/{Muse,Agent,Drawing,Hershey}.swift checks/muse-check.swift -o /tmp/muse-check
MODEL_API_KEY=... /tmp/muse-check [folder]   # 6 live calls: a PNG, a ?, plain writing, a double dot, two boxes drawn into PNGs
```

`checks/pipeline-check.swift` runs on an iPad simulator. It writes "x² = 49 ?", and "triangle" with an empty box under it, as PencilKit strokes and sends them through the app's own grouping, red crops, agent and agent pen. Its header has the commands. 29 Oct: the ? was answered in 4.3 s; the box was read and filled with a triangle in 9.2 s.

28 Oct, low effort: reading "2 + 2 = ?" took 1.9–2.3 s and about 100–200 output tokens (at the API's default high effort, "say hi" took 678). The agent read "x² = 49 ?" as a question with a nudge, a hint and "x = 7 or x = -7" in 2.6 s, left plain writing alone in 2.3 s, and explained a double-dotted word in 3.9 s. 29 Oct, boxes (the drawing call runs at medium effort): a labelled water cycle in 26 s, read and drawn; the graph of y = x^2 - 4 in 5.7 s.

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
echo 'MODEL_API_KEY = <your Meta Model API key>' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

The app reads the key from its Info.plist, so it ends up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.

## Credits

Agent labels are written in Hershey Simplex Sans (`Maple/futural.jhf`). The Hershey Fonts were originally created by Dr. A. V. Hershey at the U.S. National Bureau of Standards; see `Maple/Hershey-LICENSE.txt`.
