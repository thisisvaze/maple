# Maple

A notebook that thinks with you.

Write a weekend's costs down a page, then "split 4 ways ?", and lift the pencil. Beside it, in blue ink: "Total is 1033.92. Each pays 258.48." Draw an empty box under "height over time", and the curve draws itself in. Circle a card in coral and write "suggest a recipe", and only that card redraws. No screenshot, no switching apps, no retyping the page.

Maple is a pen-and-paper workspace for iPad and Apple Pencil. Each time the pen rests, TypeSafe's Jev reads which mark you made, in about 0.2 s. Plain writing is left alone. A `?`, a double dot, an empty box, a trailing `=` or `…`, an empty bullet, or a coral mark wakes Meta's Muse Spark, which sees the page as a picture and writes its answer in ink beside the mark, draws inside the box, or changes its own work. Plain code checks what comes back: a calculator for every number, real geometry for diagrams, and a memory that keeps only your own words.

Built from scratch for the [Meta Global AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon) (Indie Developer track, "Build for Your World"), Oct 27 – Nov 4, 2026. Every commit in this repository was made during the event. Every word Maple says, in the app, this README and the video, follows [VOICE.md](VOICE.md).

## Marks

0.6 s after the pen rests, Jev reads the gesture the new ink makes. A confirmed mark shows briefly above the tool dock, without confidence scores.

- **`?`** is answered in Maple's fine blue pen right beside it, in Handlee's hand with real math (powers, ±, √, Greek).
- **A double dot**, which the iPad reads from its timing, is answered the same way.
- **`??`** thinks harder: the question goes to Muse Wonder at medium effort instead of Spark at minimal. Its longer answer, explaining why, is written in ink like any answer, and stays a quiet dot only when there's no room (15 to 18 s for "why is e^iπ = −1 ??"). Like every answer, it streams: tap the thinking dot to watch it arrive, Wonder's summary of its thinking first when it gives one.
- **`=` with nothing after it** gets only the value, on the rest of the line: "75% of 500 g =" gets 375 g, and "R =" gets 8.314 J/(mol·K).
- **`…` trailing off a sequence or a list** carries it on in the same pattern: "1, 1, 2, 3, 5, …" gets 8, 13, 21. Both of these take the size and baseline of the line's letters, not of the small sign. A `…` on its own line under a list carries the list on down the page: about three more items, one per line, each with a bullet like yours or the next number.
- **An empty bullet** under a list, a dash, a dot, a number like "3." or a tick box, gets the next item written after it, at the list's size: under "– passport, – charger", a new "–" gets "sunscreen". Draw another and it gets the next. If you start writing after the bullet yourself, Maple leaves it to you.
- **An empty box** is drawn in, from the writing around it. See [Boxes](#boxes).
- **Coral marks** change what Maple drew or wrote. See [Edit brush](#edit-brush).

Room picks the spot so an answer never lands on your writing: the rest of the line, the line below, the nearest gap, or a gap further off with a dashed line back. It reads the line level on a slant or a turned page. Maple writes on the page only while the pen rests, so it never cuts a stroke short. The answer is real ink: it saves, zooms, erases and undoes like yours, each change on its own undo without touching your later writing, and VoiceOver reads it. While Muse answers, a small blue scribble loops at the mark. Writing over an answer fades it under the new writing until that writing is gone; scribbling an answer out removes it, in one undo.

Answers are grounded: Muse hands every number that needs working out to the app's own calculator (a small math grammar, never run as code), and searches the web for anything current, like recent events or prices.

Quiet dots: only text the pen can't write exactly, and answers with no room, stay a dot that opens into a compact paper bubble. Everything else, a `??`'s longer answer and an exact text included, is ink.

### Boxes

Muse draws in an empty box with Maple's blue colored pencil: a line drawing in named parts with labels in Maple's hand, or a graph the app plots itself. One undo takes it away. While it's drawn, the scribble loops over a quiet texture in the box, without loading text.

- **Exact diagrams:** when angles and lengths have to be true (a 3-4-5 triangle, a road bike frame), Muse gives each point as an expression in real units. The app works them out, scales the figure evenly into the box and measures every length and angle it labels, so a label can't disagree with the ink. A stated value the points don't meet goes back to Muse once with the reason.
- **Computed pictures:** for what physics actually produces (hydrogen's 1s density, two-slit interference, a dipole's field lines, an orbit), Muse gives the equations and the app shades every pixel, traces flow lines with Runge–Kutta and plots curves, at one scale across and up.
- **Pictures:** a photo, painting or scene goes to Muse Image at the box's shape (about 10 s, $0.01), under the ink so you can write on it. Pictures save, reload, undo, scratch out and show on page cards. The edit brush repaints one from a copy with your marks on it, changing only what you marked.
- **Asks first:** a label with two real meanings, like Mercury alone, gets a question in ink beside the box ("The planet or the element?"). Your next mark in the box or on the question is the reply, and the box fills.

### Maple's hand

Answers and the Me page are written in a fine blue pen, smooth and tapered like handwriting; drawings are in a blue colored pencil. A drawing's lines press and lift, lift at sharp corners so each side of a box crosses the next, close a circle by running a little past where it began, and bow gently off true when long. Muse gives each part a role: outlines are drawn heavier, axes, guides and inner details lighter, and an arrow's head is two quick flicks out from its tip. A colored part (yellow, green, blue or pink) is shaded softly with the side of the pencil, under its lines: a light wash that labels read over, in dark mode too. Under your label, a graph doesn't write that label again. Small labels are written finer than big ones. Every variation is seeded by the line itself, so an edit leaves what it kept untouched, and drawings saved before this keep the look they were drawn in. A drawing draws itself in at a hand's pace (coloring, then lines, then labels), and an edit draws in only what changed; answers write themselves in the same way, and what's revealed is the real ink.

### Edit brush

Pencil double-tap cycles pen, eraser and edit brush. The eraser rubs out anything on the page: ink, a picture where it passes (rub it all away and it's gone), and the quiet dot of an answer, all in one undo with the ink it erased. Coral marks (circles, arrows, crossings-out, a few words) change Maple's own drawings and answers. After a 1.5 s rest, Muse gets the targets with the marks in red; a drawing is redrawn in its own box, only in the parts that change, and an answer is rewritten in place. The marks fade away, all as one undo. An unclear instruction gets a short question; a failed request leaves an orange dot to try again.

With speech: circle up to four Maple drawings or pictures, then squeeze and say "Make these the same size and put them side by side." Recording holds the pending marks; Spark receives those marks, the transcript, target IDs and both page images, including pictures. Structured output can move and uniformly resize whole drawings, keeping their aspect ratios and matching widths for "same size." A move keeps the existing picture file. The whole batch is one undo. Overlap, off-screen placements and changed selections are rejected before landing; your handwriting stays. Clarification leaves the marks in place, and the next spoken or written instruction includes the previous question.

## Ask out loud

Off by default, in the gallery's Settings. Hold an Apple Pencil Pro squeeze to record, release to send; a microphone button is also there. Muse Voice Transcribe turns the recording into text, then Spark answers with the visible page as context in a saved bubble. Room places it near the latest visible writing, clear of ink and other replies where space permits, without another model call. Ask it to draw, sketch, plot or picture something and Spark calls a `draw_box` tool: Maple frames a box in its own pen in a clear spot near the latest writing (smaller if the asked size doesn't fit), then fills it like a box you drew, from what you said.

Voice uses the [file transcription endpoint](https://dev.meta.ai/docs/speech-to-text#transcribe-a-file): mono, 16-bit PCM WAV at 24 kHz, up to one minute. At the time limit, the microphone stops and waits for release. Releasing while microphone permission is pending cancels the start; squeeze again after granting permission. Canceled squeezes discard the recording. The microphone button also supports tap to start and stop (and sends automatically at the limit); tap while processing to cancel. Leaving the page, backgrounding, audio interruptions, or turning voice off cancels it and removes temporary audio. Turning the toggle on alone never requests microphone access or records. A spoken drawing request becomes up to three boxes, each a separate undo step from its drawing; a reply bubble opens only when Spark also has something to say. Double-tap still switches tools, and a system-disabled squeeze is ignored. Only transcripts and answers are saved with the page.

The **Maple on / Maple off** button beside Record pauses everything Maple does: mark recognition, answers, drawings, edits, voice, page naming and reading the Me page. It cancels requests and discards answers waiting to land; existing ink and answers stay. The setting persists across pages and launches. Drawing, erasing, perfect shapes, saving and undo remain available. Record stays visible but disabled while Maple is off.

## Connections

Off by default, in the gallery's Settings: Gmail, Calendar, Reminders, Contacts and Photos. When one is on, Spark can look through it while it answers a ? or a spoken question: `search_email`, `find_events`, `find_reminders`, `find_contacts` and `find_photos`. Ask "when does my flight leave?" or "what was the total on Tuesday's receipt?" and the answer lands beside your mark. Maple only reads, never changes anything. Photos go to Spark as pictures, up to 4 at a time at 1024 px, so it can read a whiteboard or a receipt. Calendar, Reminders, Contacts and Photos use iPadOS's own permission, asked the first time you turn one on; Gmail signs in with Google. What Spark reads goes to Meta with your question.

## Maple remembers

Every model call reads what Maple remembers about you, on every page. An answer only proposes a memory: plain code checks that each claim quotes your own words, that it isn't new wording of something you struck, and that nothing you wrote gets changed, then commits and logs it. "Noted: Is a nurse" shows for a moment. The Me page, opened from its own button at the top of the gallery, shows it all in ink: strike a line and it's forgotten at once, undo brings it back, and whatever you write there stands in your own words. It stays on the iPad in `memory.json`, and goes to Meta with each model call.

## Pages

- A Pencil-only canvas on a large sheet: two-finger pan, pinch and rotation, autosave a second after the pen pauses. Each page remembers its position, zoom and angle.
- The gallery: page cards with cached thumbnails (light and dark), + for a new page, zoom open and close, select and delete.
- Page names: Muse names a page from its ink ("Trip to Lisbon" in 1.5 s), shown beside the Pages button while you write, and names it again when the ink changes, until you tap the name, in the gallery or on the page, and give it your own. On the page you can write it with Apple Pencil, and Scribble's scratch out and circle work there. An empty name hands it back to Maple.
- Two-finger tap undoes, three-finger tap redoes. The last 100 changes and their redo position survive closing a page or restarting the app. History stores changed strokes and notes, with the current page in one atomic save; existing pages start building history when opened.
- Perfect shapes, like Procreate's QuickShape: draw and rest the pen, and after a moment the stroke snaps into the line, arc, polyline, ellipse, circle, triangle, rectangle or quadrilateral it was meant to be. Still holding, drag to turn and scale it. A finger down locks it to 15° steps by the screen, and makes a circle, a square or an equilateral triangle. It lands as your own ink, one undo, and a box snapped square is still a box for Maple to fill. Writing is left alone, and a resting palm doesn't count as a finger.
- Quick menu, like Procreate's Copy & Paste: swipe three fingers down the page, and it opens at the bottom of the screen. **Copy for AI** puts the page on the clipboard as JSON for any AI: what Maple remembers about you, every answer and drawing with what Maple read and what it was made from, and the ink, simplified. **Copy SVG** copies the ink and pictures as SVG. Both leave out edit marks. **Clear Page** asks first, then removes all the ink and answers in one step that a two-finger tap undoes; the Me page doesn't offer it. VoiceOver offers the same actions.

The controls follow the approved fuller-original study in `design/`: a shared capsule for Maple and voice, a tool dock scaled to 0.75×, centered at the top, compact recognition and confirmation messages immediately left of the Maple controls, retry surfaces, and a recording timer with microphone-level waveform. The same pencil scribble appears in small controls, answers, image loading and gallery thumbnails. State changes take 280 ms, presses 180 ms and image reveals 500 ms; Reduce Motion removes these transitions. The app icon is a pencil scribble that straightens into a glowing arrow: a rough thought turned into a direction.

## The pencil's sound

Settings opens a compact charcoal panel from the gallery. Preferences lets you choose System, Light, or Dark appearance, turn pencil sounds on or off and set their volume, and turn Perfect Shapes on or off. These choices stay across launches. Ask Out Loud is here too; Gestures & Marks shows how to write a mark, switch tools, move the page, undo, redo, and open the copy menu.

Pencil movement makes its own sound: `PencilSynth` synthesizes graphite on paper as you draw, on the audio thread of an `AVAudioEngine`. The nib reads a paper-tooth profile laid out along the stroke, so a slow line rasps low and sparse and a quick one hisses bright and dense, the way real paper does, with graphite crackle and a little body from the sheet. Speed (smoothed over 40 ms, in screen points) and pressure steer it; a resting pen goes quiet in 60 ms and a lifted one whispers out over 30 ms. There's no pen-down tap, since the Pencil already taps the glass. It respects silent mode, mixes with music, and stops for voice capture, interruptions and backgrounding. No recordings, audio services or dependencies; see `Maple/Pencil-LICENSE.txt`. `checks/pencil-check.swift` measures the response on the Mac (silent at rest, louder and brighter with speed, centered near 2.2 kHz at writing speed, no pitch of its own). Speaker level and feel still need listening on a physical iPad.

Eraser and edit have distinct materials in that same engine: a warm rubber rub around 600 Hz and a lighter felt swish around 3 kHz at writing speed. Both follow movement and pressure, settle to silence on lift, and stay muted during microphone capture. Toolbar selection and Pencil double-tap choose the sound together with the tool. The original pencil renders byte-for-byte identically; the sound checks cover the new textures, level balance, safe output and soft tool changes.

## Models

| Model | Used for |
|---|---|
| `muse-spark-1.3` (Meta) | Answering pen or voice questions (with web search and a calculate tool), drawing in a box, and editing ink, all at minimal effort |
| `muse-wonder-1.0` (Meta) | Answering a `??`, at medium effort, with the same tools as Spark; uses the same Meta API key |
| `muse-image-1.0` (Meta) | Painting a picture in a box, and repainting one from the edit brush's marks; uses the same Meta API key |
| `muse-voice-transcribe-1.0` (Meta) | Transcribing a recorded question when Ask Out Loud is on; uses the same Meta API key |
| `jev-1.13.0` (TypeSafe) | The first look at every mark: which gesture it is, in about 0.2 s |

Muse is called through the Responses API with text and PNG, at minimal reasoning effort unless a `??` asks for more. Answers to marks stream over server-sent events, with a reasoning summary; box fills and edits don't, since nothing shows until they're whole.

## Run it

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
printf 'MODEL_API_KEY = <Meta Model API key>\nTYPESAFE_API_KEY = <TypeSafe key, for Jev>\n' > Secrets.xcconfig   # gitignored
xcodegen
open Maple.xcodeproj
```

To let Maple search Gmail, turn on the Gmail API in a Google Cloud project, make an OAuth client of type iOS for the bundle ID `dev.maple.muse`, and add `GOOGLE_CLIENT_ID = <client ID>` to Secrets.xcconfig. While the consent screen is in testing, add each Google account that will connect as a test user. Then connect in Settings. Maple asks only to read mail, and the sign-in stays in the iPad's Keychain.

The app reads the keys from its Info.plist, so they end up inside the built app. That's fine for a demo on your own iPad. Move the calls behind a server before you distribute it.

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
swiftc -swift-version 6 -parse-as-library Maple/{Gmail,Muse}.swift checks/gmail-check.swift -o /tmp/gmail-check && /tmp/gmail-check
swiftc -swift-version 6 -parse-as-library Maple/{Muse,MuseImage,Memory,Agent,Drawing,Figure,Computed,Hershey,Jev}.swift checks/live-check.swift -o /tmp/live-check
MODEL_API_KEY=... TYPESAFE_API_KEY=... /tmp/live-check [folder]   # Jev reads marks; Muse answers, draws, edits a drawing and an answer
```

`checks/pipeline-check.swift`, `checks/canvas-check.swift` and `checks/recognition-check.swift` run on an iPad simulator, and `checks/device/` on a physical iPad; each file's header has its commands. What every check covers, and the timings measured along the way, are in [checks/README.md](checks/README.md).

## Credits

Maple is under the MIT License; see [LICENSE](LICENSE). The fonts below keep their own licenses.

Maple writes its answers and drawing labels in Maple Hand: [Handlee](https://fonts.google.com/specimen/Handlee) by Joe Prince (SIL Open Font License 1.1) traced into pen strokes (`Maple/hand.json`), so they are real ink; answer bubbles use the system font. See `Maple/Hand-LICENSE.txt`. Greek letters and a few signs are written in Hershey Greek (`Maple/greek.jhf`). The Hershey Fonts were originally created by Dr. A. V. Hershey at the U.S. National Bureau of Standards; see `Maple/Hershey-LICENSE.txt`.
