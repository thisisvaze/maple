# Maple

A notebook that thinks with you.

For visual thinkers who work ideas out with a pencil. Made for iPad and Apple Pencil.

[Visit Maple](https://thisisvaze.github.io/maple/)

- **Write a question.** Add a `?`, lift the pencil, and Maple writes an answer beside it.
- **Draw an empty box.** Maple fills it with a diagram, graph, or picture from the words around it.
- **Mark a change.** Circle part of Maple’s work with the edit brush and write what you want changed.

Your sketches, questions, and ideas stay together on the page.

## Run locally

Requires Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Meta and TypeSafe API keys.

Create `Secrets.xcconfig` (gitignored):

```xcconfig
MODEL_API_KEY = <Meta API key>
TYPESAFE_API_KEY = <TypeSafe API key>
```

Then run:

```sh
xcodegen
open Maple.xcodeproj
```

Local builds embed your keys. Move API calls behind a server before distributing the app.

## Credits

Uses Meta’s Muse models and TypeSafe’s Jev. Handwriting uses [Kalam](Maple/Hand-LICENSE.txt) and [Hershey](Maple/Hershey-LICENSE.txt).

[Checks](checks/README.md) · [MIT License](LICENSE)
