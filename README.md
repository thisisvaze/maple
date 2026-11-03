# Maple

A notebook that thinks with you: a pen-and-paper workspace for iPad and Apple Pencil, where Maple answers the marks you make on the page. Write a `?`, double-tap a spot, or draw an empty box: TypeSafe's Jev reads which mark it is, and Meta's Muse Spark writes its answer in ink beside the mark, or draws inside the box. With the edit brush, coral marks tell it what to change in its own drawings and answers.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event.

Every word Maple says, in the app, this README and the video, follows [VOICE.md](VOICE.md).

## Status

- [x] iPad project
- [x] Pencil-only canvas on a large sheet: two-finger pan, pinch and rotation, autosave a second after the pen pauses; each page remembers its position, zoom and angle
- [x] Gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete
- [x] Page names: Muse names a page from its ink once it closes ("Trip to Lisbon" in 1.5 s), and names it again when the ink changes, until you tap the name and give it your own. An empty name hands it back to Maple
- [x] Two-finger tap undo, three-finger tap redo; the last 100 changes and their redo position survive closing a page or restarting the app. History stores changed strokes and notes, with the current page in one atomic save. Existing pages start building history when opened. Pencil double-tap cycles pen, eraser and edit brush
- [x] Muse Spark 1.3 client (Responses API: text and PNG input, minimal reasoning effort by default)
- [x] Ask out loud (optional, off by default in gallery Settings): hold an Apple Pencil Pro squeeze to record, release to send; a microphone button is also available. Muse Voice Transcribe turns the recording into text, then Spark answers with the visible page as context in a saved bubble. Room places it near the latest visible writing, clear of ink and other replies where space permits, without another model call. Ask it to draw, sketch, plot or picture something and Spark calls a `draw_box` tool: Maple frames a box in its own pen in a clear spot near the latest writing (smaller if the asked size doesn't fit), then fills it like a box you drew, from what you said
- [x] Marks: 0.6 s after the pen rests, Jev reads the gesture the new ink makes; a `?`, a `??`, an `=` or `…` ending a line, or an empty box wakes Muse, and so does a double dot, which the iPad reads from its timing. A confirmed gesture shows briefly above the tool dock, without confidence scores.
- [x] Fill in and carry on: an `=` with nothing after it gets only the value, on the rest of the line ("75% of 500 g =" gets 375 g, "R =" gets 8.314 J/(mol·K)). Three dots trailing off a sequence or a list carry it on in the same pattern ("1, 1, 2, 3, 5, …" gets 8, 13, 21). Both answers take the size and baseline of the line's letters, not of the small sign.
- [x] Think harder: `??` sends the question to Muse Wonder at medium effort instead of Spark at minimal. Its longer answer, explaining why, waits behind a quiet dot (15 to 18 s for "why is e^iπ = −1 ??", 3 Nov).
- [x] Answers in ink: a `?` or a double dot is answered in Maple's blue pencil right beside it, once the pen rests, in Handlee's hand with real math (powers, ±, √, Greek). Room picks the spot so it never lands on the person's writing: the rest of the line, the line below, the nearest gap, or a gap further off with a dashed line back. It reads the line level on a slant or a turned page. The answer is real ink: it saves, zooms, erases and undoes like the person's, and VoiceOver reads it. While Muse answers, an opal thinking orb sits at the mark
- [x] Answers are grounded: Muse hands every number that needs working out to the app's own calculator (a small math grammar, never run as code), and searches the web for anything current, like recent events or prices
- [x] Quiet dots: exact texts asked for by name (a quote, a poem, a named problem), text the pen can't write exactly, and answers with no room stay a dot that opens into a compact paper bubble
- [x] Writing over an answer fades it under the new writing until that writing is gone; scribbling an answer or drawing out removes it, in one undo
- [x] Edit brush: coral marks (circles, arrows, crossings-out, a few words) change Maple's own drawings and answers. After a 1.5 s rest, Muse gets the targets with the marks in red; a drawing is redrawn in its own box, only in the parts that change, and an answer is rewritten in place. The marks fade away, all as one undo. An unclear instruction gets a short question; a failed request leaves an orange dot to try again
- [x] Edit brush + speech: circle up to four Maple drawings or pictures, then squeeze and say “Make these the same size and put them side by side.” Recording holds the pending marks; Spark receives those marks, the transcript, target IDs and both page images, including pictures. Strict structured output can move and uniformly resize whole drawings, keeping their aspect ratios and matching widths for “same size.” A move keeps the existing picture file. The whole batch is one undo. Overlap, off-screen placements and changed selections are rejected before landing; the person's handwriting stays. Clarification leaves the marks in place, and the next spoken or written instruction includes the previous question
- [x] Maple writes on the page only while the pen rests, so it never cuts a stroke short, and each change undoes on its own without touching the person's later writing
- [x] App icon: a pencil scribble that straightens into a glowing arrow, a rough thought the AI turns into a direction
- [x] Empty box: Muse draws in it with the agent's blue pencil: a line drawing in named parts with pen-font labels, or a graph the app plots itself; one undo takes it away. While it's drawn, the fuller opal orb sits over a quiet texture in the box, without visible loading text.
- [x] Maple's hand (3 Nov): it writes and draws in a blue colored pencil, with a pencil's grain, ends that set down and lift a little thinner, and long lines that bow gently off true (the same line always the same way, so an edit leaves what it kept untouched). Small labels are written finer than big ones. Muse can color a part in yellow, green, blue or pink, and the app shades its closed shapes with pencil zig-zags inside the line, under the labels. A drawing draws itself in at a hand's pace (outlines, then coloring, then labels), and an edit draws in only what changed; answers write themselves in the same way, and what's revealed is the real ink, grain and all
- [x] Exact diagrams: when angles and lengths have to be true (a 3-4-5 triangle, a road bike frame), Muse gives each point as an expression in real units. The app works them out, scales the figure evenly into the box and measures every length and angle it labels, so a label can't disagree with the ink. A stated value the points don't meet goes back to Muse once with the reason.
- [x] Computed pictures: for what physics actually produces (hydrogen's 1s density, two-slit interference, a dipole's field lines, an orbit), Muse gives the equations and the app shades every pixel, traces flow lines with Runge–Kutta and plots curves, at one scale across and up.
- [x] Pictures: a photo, painting or scene goes to Muse Image at the box's shape (about 10 s, $0.01), under the ink so you can write on it. Pictures save, reload, undo, scratch out and show on page cards. The edit brush repaints one from a copy with your marks on it, changing only what you marked.
- [x] Perfect shapes, like Procreate's QuickShape: draw and rest the pen, and after a moment the stroke snaps into the line, arc, polyline, ellipse, circle, triangle, rectangle or quadrilateral it was meant to be. Still holding, drag to turn and scale it. A finger down locks it to fifteen-degree steps by the screen, and makes a circle, a square or an equilateral triangle. It lands as your own ink, one undo, and a box snapped square is still a box for Maple to fill. Writing is left alone, and a resting palm doesn't count as a finger.
- [x] Quick menu, like Procreate's Copy & Paste: swipe three fingers down the page. **Copy for AI** puts the page on the clipboard as JSON for any AI: what Maple remembers about you, every answer and drawing with what Maple read and what it was made from, and the ink, simplified. **Copy SVG** copies the ink and pictures as SVG. Both leave out edit marks, and VoiceOver offers the same two actions.
- [x] Asks first: a label with two real meanings, like Mercury alone, gets a question in ink beside the box ("The planet or the element?"). Your next mark in the box or on the question is the reply, and the box fills.
- [x] Shared memory: every agent reads what Maple remembers about you, on every page. The Answer agent only proposes: plain code checks that each claim quotes your own words, that it isn't new wording of something you struck, and that nothing you wrote gets changed, then commits and logs it. "Noted: Is a nurse" shows for a moment. The Me page, pinned first in the gallery, shows it all in ink: strike a line and it's forgotten at once, undo brings it back, and whatever you write there stands in your own words. It stays on the iPad in `memory.json`, and goes to Meta with each model call.

## Models

| Model | Used for |
|---|---|
| `muse-spark-1.3` (Meta) | Answering pen or voice questions (with web search and a calculate tool), drawing in a box, and editing ink, all at minimal effort |
| `muse-wonder-1.0` (Meta) | Answering a `??`, at medium effort, with the same tools as Spark; uses the same Meta API key |
| `muse-image-1.0` (Meta) | Painting a picture in a box, and repainting one from the edit brush's marks; uses the same Meta API key |
| `muse-voice-transcribe-1.0` (Meta) | Transcribing a recorded question when Ask Out Loud is on; uses the same Meta API key |
| `jev-1.13.0` (TypeSafe) | The first look at every mark: which gesture it is, in about 0.2 s |

## Voice

Voice uses the [file transcription endpoint](https://dev.meta.ai/docs/speech-to-text#transcribe-a-file): mono, 16-bit PCM WAV at 24 kHz, up to one minute. Hold a Pencil Pro squeeze to record and release to send. At the time limit, the microphone stops and waits for release. Releasing while microphone permission is pending cancels the start; squeeze again after granting permission. Canceled squeezes discard the recording. The microphone button also supports tap to start/stop (and sends automatically at the limit); tap while processing to cancel. Leaving the page, backgrounding, audio interruptions, or disabling voice cancels it and removes temporary audio. Enabling the toggle alone never requests microphone access or records. A spoken drawing request becomes up to three boxes, each a separate undo step from its drawing; a reply bubble opens only when Spark also has something to say. Double-tap still switches tools, and a system-disabled squeeze is ignored. Only transcripts and answers are saved with the page.

The **Maple on / Maple off** button beside Record pauses all model actions, including mark recognition, answers, drawings, edits, voice, automatic page naming and reading the Me page. It cancels requests and discards answers waiting to land; existing ink and answers stay. The setting persists across pages and launches. Drawing, erasing, QuickShape, saving and undo remain available. Record stays visible but disabled while AI is off.

The native controls follow the approved fuller-original study in `design/`: a shared capsule for AI and voice, a tool dock scaled to 0.75× beside Pages at top left, compact recognition and confirmation messages immediately left of the AI controls, retry surfaces, and a recording timer with microphone-level waveform. The same retained vector orb appears in small controls, answers, image loading and gallery thumbnails. State changes take 280 ms, presses 180 ms and image reveals 500 ms; Reduce Motion removes these transitions. Canvas checks cover the orb geometry and vector layers, stable voice-button widths, tool selection and AI-off behavior.

Pencil movement makes its own sound: `PencilSynth` synthesizes graphite on paper as you draw, on the audio thread of an `AVAudioEngine`. The nib reads a paper-tooth profile laid out along the stroke, so a slow line rasps low and sparse and a quick one hisses bright and dense, the way real paper does, with graphite crackle and a little body from the sheet. Speed (smoothed over 40 ms, in screen points) and pressure steer it; a resting pen goes quiet in 60 ms and a lifted one whispers out over 30 ms. There's no pen-down tap, since the Pencil already taps the glass. It respects silent mode, mixes with music, and stops for voice capture, interruptions and backgrounding. No recordings, audio services or dependencies; see `Maple/Pencil-LICENSE.txt`. `checks/pencil-check.swift` measures the response on the Mac (silent at rest, louder and brighter with speed, centered near 2.2 kHz at writing speed, no pitch of its own). Speaker level and feel still need listening on a physical iPad.

Eraser and edit now have distinct materials in that same engine: a warm rubber rub around 600 Hz and a lighter felt swish around 3 kHz at writing speed. Both follow movement and pressure, settle to silence on lift, and stay muted during microphone capture. Toolbar selection and Pencil double-tap choose the sound together with the tool. The original pencil renders byte-for-byte identically; the sound checks cover the new textures, level balance, safe output and soft tool changes. The device recording check runs once with each tool selected.

## Checks

They run on the Mac, without the simulator.

```sh
swiftc -swift-version 6 -O -parse-as-library Maple/Shape.swift checks/shape-check.swift -o /tmp/shape-check && /tmp/shape-check
swiftc -swift-version 6 -O -parse-as-library Maple/PencilSynth.swift checks/pencil-check.swift -o /tmp/pencil-check && /tmp/pencil-check
swiftc -swift-version 6 -parse-as-library Maple/Memory.swift checks/memory-check.swift -o /tmp/memory-check && /tmp/memory-check
swiftc -swift-version 6 -parse-as-library Maple/Grouping.swift checks/grouping-check.swift -o /tmp/grouping-check && /tmp/grouping-check
swiftc -swift-version 6 -parse-as-library Maple/{Drawing,Figure,Computed,Hershey}.swift checks/drawing-check.swift -o /tmp/drawing-check && /tmp/drawing-check
swiftc -swift-version 6 -parse-as-library Maple/Hershey.swift Maple/Handwriting.swift checks/handwriting-check.swift -o /tmp/handwriting-check && /tmp/handwriting-check
swiftc -swift-version 6 -O -parse-as-library Maple/Room.swift checks/room-check.swift -o /tmp/room-check && /tmp/room-check
swiftc -swift-version 6 -parse-as-library Maple/{Transcribe,Muse,Memory,Agent,Drawing,Figure,Computed,Hershey}.swift checks/voice-check.swift -o /tmp/voice-check && /tmp/voice-check
swiftc -swift-version 6 -parse-as-library Maple/{Muse,Memory,Agent,Drawing,Figure,Computed,Hershey}.swift checks/muse-check.swift -o /tmp/muse-check && /tmp/muse-check
swiftc -swift-version 6 -parse-as-library Maple/{Muse,MuseImage,Memory,Agent,Drawing,Figure,Computed,Hershey,Jev}.swift checks/live-check.swift -o /tmp/live-check
MODEL_API_KEY=... TYPESAFE_API_KEY=... /tmp/live-check [folder]   # Jev reads marks; Muse answers, draws, edits a drawing and an answer
```

`checks/pipeline-check.swift` runs on an iPad simulator. It writes "x² = 49 ?", and "triangle" with an empty box under it, as PencilKit strokes and sends them through the app's own grouping, red crops, Jev, Muse and agent pen. Offline it writes a known answer in ink beside the ? and renders an edit before and after; with keys, Muse's own answer too. Its header has the commands. 29 Oct: the ? was answered in 4.6 s; the box was read and filled with a triangle in 7.0 s.

`checks/canvas-check.swift` checks rotation around the fingers, screen coverage, bubble alignment, viewport restoration, resizing, undo/redo, Maple's ink surviving a reload, undo by stroke id, writing only while the pen rests, fading and scratching out answers, the reading frame, and the edit brush (tool cycle, brush width, timer, targets, landing and undo) on an iPad simulator without model keys. It also checks 100 saved history steps, redo across reloads, compact stroke deltas, partial erasure, answer notes, corrupt-save protection, and voice bubble placement on rotated and zoomed pages. Its header has the commands.

The edit checks also cover moving and resizing two generated objects together on a rotated, zoomed page, retaining picture files, scaling stored parts, one undo/redo and persistence. Invalid coordinates, overlaps and changes made during a request leave the whole batch unchanged. Mocked voice edits cover the recording hold, captured selection, clarification and a follow-up instruction. Live model interpretation of these combined edits and the physical Pencil/microphone interaction still need checking on iPad.

`checks/device/CanvasChecks.swift` covers the iPad erase crash: PencilKit can split one stroke into pieces sharing its creation date and random seed. History now compares and restores all pieces of a logical stroke together, including an unchanged sibling, instead of treating those IDs as unique. The device check covers split erasure, erasing one piece again, AI replacement, undo/redo and reopening the saved page. It also checks that AI ink stays queued during overlapping pinch/rotation and lands once both end; the writing reveal remains touch-through. User gestures themselves still need a hands-on check.

`checks/device/LoadingChecks.swift` animates zoom and rotation over three 600 × 400 image loaders and three small orbs on the physical iPad. Image textures now keep four vector paths and animate opacity; zoom never changes their bitmap scale or repaints the whole box. Orbs update their existing vector layers directly. On the M5 iPad, the five-second benchmark's 95th-percentile frame interval fell from 58.3 ms to 16.7 ms, with frames over 33 ms falling from 58 to zero. The check also covers retained paths, constant orb size, touch-through, hiding, foreground pause/resume and removal.

`checks/voice-check.swift` uses mocked API responses to check multipart audio uploads, transcription errors, cancellation, and spoken questions with page images sent to Spark. On a simulator it also checks that voice starts off, enabling doesn't request microphone permission, releasing or canceling a squeeze during setup prevents a late microphone start, disabling/backgrounding/page close cancels, and answers persist as open bubbles, and that a spoken drawing frames a box clear of the person's ink and fills it from the request. A live probe on 2 Nov called `draw_box` for a graph, a wireframe, an orbital and a triangle (2–5 s), and not for two plain questions. A live synthetic WAV was transcribed in 1.8 s on 29 Oct; physical microphone capture is covered by the device check below.

2 Nov, physical iPad: `checks/device/AudioChecks.swift` started the real microphone through the Record button three times, checked the advancing recording timer, interrupted capture from a background audio queue and verified that each new WAV was removed. This reproduces the previously crashing audio-engine callback; the same callback regression now passes in `voice-check.swift`. Run `xcodegen`, then `xcodebuild test -project Maple.xcodeproj -scheme Maple -destination 'id=<iPad UDID>' -only-testing:MapleDeviceChecks` after granting Maple microphone access. The hardware check cancels every recording without uploading audio. Pencil squeeze and an end-to-end spoken answer still need a hands-on check.

28 Oct, low effort: reading "2 + 2 = ?" took 1.9–2.3 s and about 100–200 output tokens (at the API's default high effort, "say hi" took 678). The agent read "x² = 49 ?" as a question and answered "x = 7 or x = -7" in 2.6 s, left plain writing alone in 2.3 s, and explained a double-dotted word in 3.9 s. 29 Oct, with Jev in front: Jev named a ? in 0.21 s and plain writing in 0.13 s; Muse answered the ? in 4.0 s in all (2.5 s once answers dropped the nudge and hint), drew a labeled water cycle in 24 s and plotted y = x^2 - 4 in 4.0 s (those drawing measurements used medium effort). 29 Oct, minimal effort: the ? answered in 2.6–2.9 s, a double dot in 3.8 s, the Gettysburg Address as exact text in 5.2 s; an edit relabeling a drawing's button took 4.7 s and rewriting an answer 6.4 s.

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
printf 'MODEL_API_KEY = <Meta Model API key>\nTYPESAFE_API_KEY = <TypeSafe key, for Jev>\n' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

The app reads the keys from its Info.plist, so they end up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.

## Credits

The agent writes its answers and drawing labels in Maple Hand: [Handlee](https://fonts.google.com/specimen/Handlee) by Joe Prince (SIL Open Font License 1.1) traced into pen strokes (`Maple/hand.json`), so they are real ink; answer bubbles use the system font. See `Maple/Hand-LICENSE.txt`. Greek letters and a few signs are written in Hershey Greek (`Maple/greek.jhf`). The Hershey Fonts were originally created by Dr. A. V. Hershey at the U.S. National Bureau of Standards; see `Maple/Hershey-LICENSE.txt`.

The thinking orb ports the "breathing" ring of [Thinking Orbs](https://github.com/Jakubantalik/Libraries.dev/tree/main/packages/thinking-orbs) by Jakub Antalik, MIT; see `Maple/ThinkingOrbs-LICENSE.txt`.
