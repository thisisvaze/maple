# Maple

A pen-and-paper workspace for iPad and Apple Pencil, where AI agents answer the marks you make on the page. Write a `?`, double-tap a spot, or draw an empty box: TypeSafe's Jev reads which mark it is, and Meta's Muse Spark writes its answer in ink beside the mark, or draws inside the box. With the edit brush, coral marks tell it what to change in its own drawings and answers.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event.

## Status

- [x] iPad project
- [x] Pencil-only canvas on a large sheet: two-finger pan, pinch and rotation, autosave a second after the pen pauses; each page remembers its position, zoom and angle
- [x] Gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete
- [x] Two-finger tap undo, three-finger tap redo, Pencil double-tap cycles pen, eraser and edit brush
- [x] Muse Spark 1.3 client (Responses API: text and PNG input, minimal reasoning effort by default)
- [x] Optional voice input: off by default in gallery Settings. Hold an Apple Pencil Pro squeeze to record, release to send; a microphone button is also available. Muse Voice Transcribe turns the recording into text, then Spark answers with the visible page as context in a saved bubble
- [x] Marks: 0.6 s after the pen rests, Jev reads the gesture the new ink makes; a `?` or an empty box wakes Muse, and so does a double dot, which the iPad reads from its timing. Jev's verdict shows in the top-right corner for 3 s ("question 97%", "maybe frame 62%")
- [x] Answers in ink: a `?` or a double dot is answered in Maple's blue pen right beside it, once the pen rests, in a Hershey cursive hand with real maths (powers, ±, √, Greek). Room picks the spot so it never lands on the person's writing: the rest of the line, the line below, the nearest gap, or a gap further off with a dashed line back. It reads the line level on a slant or a turned page. The answer is real ink: it saves, zooms, erases and undoes like the person's, and VoiceOver reads it. While Muse answers, an opal thinking orb sits at the mark
- [x] Quiet dots: exact texts asked for by name (a quote, a poem, a named problem), text the pen can't write exactly, and answers with no room stay a dot that opens into a glass bubble
- [x] Writing over an answer fades it under the new writing until that writing is gone; scribbling an answer or drawing out removes it, in one undo
- [x] Edit brush: coral marks (circles, arrows, crossings-out, a few words) change Maple's own drawings and answers. After a 1.5 s rest, Muse gets the targets with the marks in red; a drawing is redrawn in its own box, only in the parts that change, and an answer is rewritten in place. The marks fade away, all as one undo. Marks Muse can't read stay with an orange dot to try again
- [x] Maple writes on the page only while the pen rests, so it never cuts a stroke short, and each change undoes on its own without touching the person's later writing
- [x] App icon: a pencil scribble that straightens into a glowing arrow, a rough thought the AI turns into a direction
- [x] Empty box: Muse draws in it with the agent's blue pen: a line drawing in named parts with pen-font labels, or a graph the app plots itself; one undo takes it away. While it's drawn, a grey pixel grid shimmers in the box
- [ ] Shared memory the agents read and propose changes to

## Models

| Model | Used for |
|---|---|
| `muse-spark-1.3` (Meta) | Answering pen or voice questions, drawing in a box, and editing ink, all at minimal effort |
| `muse-voice-transcribe-1.0` (Meta) | Transcribing a recorded question when voice input is enabled; uses the same Meta API key |
| `jev-1.13.0` (TypeSafe) | The first look at every mark: which gesture it is, in about 0.2 s |

## Voice input

Voice input uses the [file transcription endpoint](https://dev.meta.ai/docs/speech-to-text#transcribe-a-file): mono, 16-bit PCM WAV at 24 kHz, up to one minute. Hold a Pencil Pro squeeze to record and release to send. At the time limit, the microphone stops and waits for release. Releasing while microphone permission is pending cancels the start; squeeze again after granting permission. Cancelled squeezes discard the recording. The microphone button also supports tap to start/stop (and sends automatically at the limit); tap while processing to cancel. Leaving the page, backgrounding, audio interruptions, or disabling voice cancels it and removes temporary audio. Enabling the toggle alone never requests microphone access or records. Double-tap still switches tools, and a system-disabled squeeze is ignored. Only transcripts and answers are saved with the page.

## Checks

They run on the Mac, without the simulator.

```sh
swiftc -swift-version 6 -parse-as-library Maple/Grouping.swift checks/grouping-check.swift -o /tmp/grouping-check && /tmp/grouping-check
swiftc -swift-version 6 -parse-as-library Maple/Drawing.swift Maple/Hershey.swift checks/drawing-check.swift -o /tmp/drawing-check && /tmp/drawing-check
swiftc -swift-version 6 -parse-as-library Maple/Hershey.swift Maple/Handwriting.swift checks/handwriting-check.swift -o /tmp/handwriting-check && /tmp/handwriting-check
swiftc -swift-version 6 -O -parse-as-library Maple/Room.swift checks/room-check.swift -o /tmp/room-check && /tmp/room-check
swiftc -swift-version 6 -parse-as-library Maple/{Transcribe,Muse,Agent,Drawing,Hershey}.swift checks/voice-check.swift -o /tmp/voice-check && /tmp/voice-check
swiftc -swift-version 6 -parse-as-library Maple/{Muse,Agent,Drawing,Hershey,Jev}.swift checks/live-check.swift -o /tmp/live-check
MODEL_API_KEY=... TYPESAFE_API_KEY=... /tmp/live-check [folder]   # Jev reads marks; Muse answers, draws, edits a drawing and an answer
```

`checks/pipeline-check.swift` runs on an iPad simulator. It writes "x² = 49 ?", and "triangle" with an empty box under it, as PencilKit strokes and sends them through the app's own grouping, red crops, Jev, Muse and agent pen. Offline it writes a known answer in ink beside the ? and renders an edit before and after; with keys, Muse's own answer too. Its header has the commands. 29 Oct: the ? was answered in 4.6 s; the box was read and filled with a triangle in 7.0 s.

`checks/canvas-check.swift` checks rotation around the fingers, screen coverage, bubble alignment, viewport restoration, resizing, undo/redo, Maple's ink surviving a reload, undo by stroke id, writing only while the pen rests, fading and scratching out answers, the reading frame, and the edit brush (tool cycle, brush width, timer, targets, landing and undo) on an iPad simulator without model keys. Its header has the commands.

`checks/voice-check.swift` uses mocked API responses to check multipart audio uploads, transcription errors, cancellation, and spoken questions with page images sent to Spark. On a simulator it also checks that voice starts off, enabling doesn't request microphone permission, releasing or cancelling a squeeze during setup prevents a late microphone start, disabling/backgrounding/page close cancels, and answers persist as open bubbles. A live synthetic WAV was transcribed in 1.8 s on 29 Oct; physical microphone capture and Pencil squeeze behavior are still to be checked on iPad.

28 Oct, low effort: reading "2 + 2 = ?" took 1.9–2.3 s and about 100–200 output tokens (at the API's default high effort, "say hi" took 678). The agent read "x² = 49 ?" as a question and answered "x = 7 or x = -7" in 2.6 s, left plain writing alone in 2.3 s, and explained a double-dotted word in 3.9 s. 29 Oct, with Jev in front: Jev named a ? in 0.21 s and plain writing in 0.13 s; Muse answered the ? in 4.0 s in all (2.5 s once answers dropped the nudge and hint), drew a labelled water cycle in 24 s and plotted y = x^2 - 4 in 4.0 s (those drawing measurements used medium effort). 29 Oct, minimal effort: the ? answered in 2.6–2.9 s, a double dot in 3.8 s, the Gettysburg Address as exact text in 5.2 s; an edit relabelling a drawing's button took 4.7 s and rewriting an answer 6.4 s.

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
printf 'MODEL_API_KEY = <Meta Model API key>\nTYPESAFE_API_KEY = <TypeSafe key, for Jev>\n' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

The app reads the keys from its Info.plist, so they end up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.

## Credits

Agent labels are written in Hershey Simplex Sans (`Maple/futural.jhf`), and answers in Hershey Cursive (`Maple/cursive.jhf`) with Hershey Greek (`Maple/greek.jhf`) for Greek letters and signs. The Hershey Fonts were originally created by Dr. A. V. Hershey at the U.S. National Bureau of Standards; see `Maple/Hershey-LICENSE.txt`.

The thinking orb ports the "breathing" ring of [Thinking Orbs](https://github.com/Jakubantalik/Libraries.dev/tree/main/packages/thinking-orbs) by Jakub Antalik, MIT; see `Maple/ThinkingOrbs-LICENSE.txt`.
