# Maple

A pen-and-paper workspace for iPad and Apple Pencil, where AI agents answer the marks you make on the page. Write a `?`, double-tap a spot, or draw an empty box: TypeSafe's Jev reads which mark it is, and Meta's Muse Spark replies in a small bubble or draws inside the box.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event.

## Status

- [x] iPad project
- [x] Pencil-only canvas on a large sheet: two-finger pan and pinch, autosave a second after the pen pauses
- [x] Gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete
- [x] Two-finger tap undo, three-finger tap redo, Pencil double-tap swaps pen and eraser
- [x] Muse Spark 1.3 client (Responses API: text and PNG input, low reasoning effort by default)
- [x] Marks: 0.6 s after the pen rests, Jev reads the gesture the new ink makes; a `?` or an empty box wakes Muse, and so does a double dot, which the iPad reads from its timing
- [x] Answers: quiet dots that open into glass bubbles; a `?` opens a nudge, then a hint, then the answer; saved with the page. While Muse reads a double dot, its dot is an opal thinking orb
- [x] App icon: a pencil scribble that straightens into a glowing arrow, a rough thought the AI turns into a direction
- [x] Empty box: Muse draws in it with the agent's blue pen: a line drawing with pen-font labels, or a graph the app plots itself; one undo takes it away. While it's drawn, glitter twinkles in the box and a holographic sheen sweeps across
- [ ] Shared memory the agents read and propose changes to

## Models

| Model | Used for |
|---|---|
| `muse-spark-1.3` (Meta) | Answering a `?` or a double dot (low effort), drawing in a box (medium effort) |
| `jev-1.13.0` (TypeSafe) | The first look at every mark: which gesture it is, in about 0.2 s |

## Checks

They run on the Mac, without the simulator.

```sh
swiftc -swift-version 6 -parse-as-library Maple/Grouping.swift checks/grouping-check.swift -o /tmp/grouping-check && /tmp/grouping-check
swiftc -swift-version 6 -parse-as-library Maple/Drawing.swift Maple/Hershey.swift checks/drawing-check.swift -o /tmp/drawing-check && /tmp/drawing-check
swiftc -swift-version 6 -parse-as-library Maple/{Muse,Agent,Drawing,Hershey,Jev}.swift checks/live-check.swift -o /tmp/live-check
MODEL_API_KEY=... TYPESAFE_API_KEY=... /tmp/live-check [folder]   # Jev reads a ?, plain writing and two boxes; Muse answers and draws
```

`checks/pipeline-check.swift` runs on an iPad simulator. It writes "x² = 49 ?", and "triangle" with an empty box under it, as PencilKit strokes and sends them through the app's own grouping, red crops, Jev, Muse and agent pen. Its header has the commands. 29 Oct: the ? was answered in 4.6 s; the box was read and filled with a triangle in 7.0 s.

28 Oct, low effort: reading "2 + 2 = ?" took 1.9–2.3 s and about 100–200 output tokens (at the API's default high effort, "say hi" took 678). The agent read "x² = 49 ?" as a question with a nudge, a hint and "x = 7 or x = -7" in 2.6 s, left plain writing alone in 2.3 s, and explained a double-dotted word in 3.9 s. 29 Oct, with Jev in front: Jev named a ? in 0.21 s and plain writing in 0.13 s; Muse answered the ? in 4.0 s in all, drew a labelled water cycle in 24 s and plotted y = x^2 - 4 in 4.0 s (drawing runs at medium effort).

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
printf 'MODEL_API_KEY = <Meta Model API key>\nTYPESAFE_API_KEY = <TypeSafe key, for Jev>\n' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

The app reads the keys from its Info.plist, so they end up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.

## Credits

Agent labels are written in Hershey Simplex Sans (`Maple/futural.jhf`). The Hershey Fonts were originally created by Dr. A. V. Hershey at the U.S. National Bureau of Standards; see `Maple/Hershey-LICENSE.txt`.

The thinking orb ports the "breathing" ring of [Thinking Orbs](https://github.com/Jakubantalik/Libraries.dev/tree/main/packages/thinking-orbs) by Jakub Antalik, MIT; see `Maple/ThinkingOrbs-LICENSE.txt`.
