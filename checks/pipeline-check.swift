// Runs a mark through the app's own path on an iPad simulator: PencilKit strokes → Grouping → red crops → Muse.
// The strokes are letter outlines from a handwriting font, "x² = 49 ?", written a glyph at a time, the ?'s dot last.
// It runs inside a bare .app, because PencilKit saves drawing state to preferences and traps without a bundle ID.
//   S=$(mktemp -d); mkdir $S/Check.app; xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator \
//     -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -parse-as-library \
//     Maple/{Marks,Bubble,Note,Page,Grouping,Agent,Muse}.swift checks/pipeline-check.swift -o $S/Check.app/pipeline
//   plutil -create xml1 $S/Check.app/Info.plist; plutil -insert CFBundleIdentifier -string dev.maple.check $S/Check.app/Info.plist
//   SIMCTL_CHILD_MODEL_API_KEY=... xcrun simctl spawn booted $S/Check.app/pipeline $S   # also writes near.png and around.png
import PencilKit

@main
struct Check {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let strokes = handwriting("x² = 49 ?", at: CGPoint(x: 1000, y: 1000), size: 64, start: Date(timeIntervalSince1970: 1_000_000))
        let recent = strokes.map { stroke in
            let started = stroke.path.creationDate.timeIntervalSince1970
            return Grouping.Stroke(id: Marks.id(stroke), bounds: stroke.renderBounds, started: started, ended: started + (stroke.path.last?.timeOffset ?? 0))
        }
        let trigger = Grouping.candidate(recent)
        precondition(trigger == Array(recent.suffix(2).map(\.id)), "the ? is its hook and dot: \(trigger.count) strokes")

        // Built whole: mutating a PKDrawing's strokes needs an app bundle (PencilKit saves replica state to preferences).
        let marked = PKDrawing(strokes: strokes.map { stroke in
            var stroke = stroke
            if trigger.contains(Marks.id(stroke)) { stroke.ink = PKInk(stroke.ink.inkType, color: .systemRed) }
            return stroke
        })
        let mark = marked.strokes.filter { trigger.contains(Marks.id($0)) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
        let side = max(mark.width, mark.height) + 2 * Marks.nearPad
        let near = CGRect(x: mark.midX - side / 2, y: mark.midY - side / 2, width: side, height: side)
        let around = CGRect(x: 800, y: 800, width: 820, height: 1180).union(near)  // an iPad screen at zoom 1
        let (nearPNG, aroundPNG) = await Marks.crops(marked, near, around)
        try nearPNG.write(to: out.appending(path: "near.png"))
        try aroundPNG.write(to: out.appending(path: "around.png"))
        print("crops ok: \(out.path)")

        guard let key = ProcessInfo.processInfo.environment["MODEL_API_KEY"], !key.isEmpty else { return print("no MODEL_API_KEY: skipped Muse") }
        let start = ContinuousClock.now
        let answer = try await Agent(muse: Muse(key: key)).ask(near: nearPNG, around: aroundPNG, gesture: nil, threads: [], target: nil)
        print("\(answer) in \(start.duration(to: .now))")
        precondition(answer.mark == "question" && answer.reply.contains("7"), "Muse answers the written ?")
        print("pipeline ok")
    }

    /// `text` as pen strokes: each glyph's outline contours, written 0.3 s apart, the last contour (a ?'s dot) 1 s late.
    static func handwriting(_ text: String, at origin: CGPoint, size: CGFloat, start: Date) -> [PKStroke] {
        let font = CTFontCreateWithName("Noteworthy-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var strokes: [PKStroke] = [], time = start
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                for contour in contours(path) where contour.count > 1 {
                    // Glyph space has y up; the page has y down.
                    let points = contour.map { CGPoint(x: origin.x + position.x + $0.x, y: origin.y - $0.y) }
                    let samples = points.enumerated().map { i, p in
                        PKStrokePoint(location: p, timeOffset: Double(i) * 0.004, size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    }
                    strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: samples, creationDate: time)))
                    time += 0.3
                }
            }
        }
        if let dot = strokes.popLast() {  // the ?'s dot, after a pause
            strokes.append(PKStroke(ink: dot.ink, path: PKStrokePath(controlPoints: Array(dot.path), creationDate: time + 1)))
        }
        return strokes
    }

    /// A path's closed contours as points, curves sampled every 1/8.
    static func contours(_ path: CGPath) -> [[CGPoint]] {
        var all: [[CGPoint]] = [], current: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee, p = e.points
            func sample(_ f: (CGFloat) -> CGPoint) { current += (1...8).map { f(CGFloat($0) / 8) } }
            switch e.type {
            case .moveToPoint: if !current.isEmpty { all.append(current) }; current = [p[0]]
            case .addLineToPoint: current.append(p[0])
            case .addQuadCurveToPoint:
                let a = current.last!
                sample { t in CGPoint(x: (1-t)*(1-t)*a.x + 2*(1-t)*t*p[0].x + t*t*p[1].x, y: (1-t)*(1-t)*a.y + 2*(1-t)*t*p[0].y + t*t*p[1].y) }
            case .addCurveToPoint:
                let a = current.last!
                sample { t in
                    let u = 1 - t
                    return CGPoint(x: u*u*u*a.x + 3*u*u*t*p[0].x + 3*u*t*t*p[1].x + t*t*t*p[2].x, y: u*u*u*a.y + 3*u*u*t*p[0].y + 3*u*t*t*p[1].y + t*t*t*p[2].y)
                }
            case .closeSubpath: if let first = current.first { current.append(first) }
            @unknown default: break
            }
        }
        if !current.isEmpty { all.append(current) }
        return all
    }
}
