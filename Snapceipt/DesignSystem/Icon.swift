import SwiftUI
import CoreGraphics

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

extension Path {
    /// Build a Path from an SVG `d` string on the source coordinate system
    /// (icons author at a 24×24 grid). Supports M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z.
    init(svgPath d: String) {
        self.init()
        var scanner = SVGScanner(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var prevControl: CGPoint? = nil       // for S/T reflection
        var prevCmd: Character = " "
        while let cmd = scanner.nextCommand() {
            let rel = cmd.isLowercase
            switch Character(cmd.lowercased()) {
            case "m":
                var p = scanner.point(); if rel { p = current + p }
                move(to: p); current = p; start = p
                // subsequent coordinate pairs after a moveto are implicit linetos
                while scanner.hasNumber {
                    var q = scanner.point(); if rel { q = current + q }
                    addLine(to: q); current = q
                }
            case "l":
                while scanner.hasNumber {
                    var p = scanner.point(); if rel { p = current + p }
                    addLine(to: p); current = p
                }
            case "h":
                while scanner.hasNumber {
                    let x = scanner.number(); current.x = rel ? current.x + x : x
                    addLine(to: current)
                }
            case "v":
                while scanner.hasNumber {
                    let y = scanner.number(); current.y = rel ? current.y + y : y
                    addLine(to: current)
                }
            case "c":
                while scanner.hasNumber {
                    var c1 = scanner.point(); var c2 = scanner.point(); var p = scanner.point()
                    if rel { c1 = current + c1; c2 = current + c2; p = current + p }
                    addCurve(to: p, control1: c1, control2: c2); prevControl = c2; current = p
                }
            case "s":
                while scanner.hasNumber {
                    var c2 = scanner.point(); var p = scanner.point()
                    if rel { c2 = current + c2; p = current + p }
                    let useRefl = (prevCmd == "c" || prevCmd == "s")
                    let reflected = useRefl ? current + (current - (prevControl ?? current)) : current
                    addCurve(to: p, control1: reflected, control2: c2); prevControl = c2; current = p
                }
            case "q":
                while scanner.hasNumber {
                    var c = scanner.point(); var p = scanner.point()
                    if rel { c = current + c; p = current + p }
                    addQuadCurve(to: p, control: c); prevControl = c; current = p
                }
            case "t":
                while scanner.hasNumber {
                    var p = scanner.point(); if rel { p = current + p }
                    let useRefl = (prevCmd == "q" || prevCmd == "t")
                    let c = useRefl ? current + (current - (prevControl ?? current)) : current
                    addQuadCurve(to: p, control: c); prevControl = c; current = p
                }
            case "a":
                while scanner.hasNumber {
                    let rx = scanner.number(), ry = scanner.number(), rot = scanner.number()
                    let large = scanner.flag(), sweep = scanner.flag()
                    var p = scanner.point(); if rel { p = current + p }
                    SVGArc.append(to: &self, from: current, to: p, rx: rx, ry: ry,
                                  xAxisRotationDeg: rot, largeArc: large, sweep: sweep)
                    current = p
                }
            case "z":
                closeSubpath(); current = start
            default:
                break
            }
            prevCmd = Character(cmd.lowercased())
            if prevCmd != "c" && prevCmd != "s" && prevCmd != "q" && prevCmd != "t" { prevControl = nil }
        }
    }
}

/// Tokenizes an SVG path: command letters + SVG floats (handles "0-8.2", ".5.5", flags).
private struct SVGScanner {
    private let s: [Character]; private var i = 0
    init(_ str: String) { s = Array(str) }
    private mutating func skipSep() {
        while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
    }
    mutating func nextCommand() -> Character? {
        skipSep()
        guard i < s.count else { return nil }
        if s[i].isLetter { let c = s[i]; i += 1; return c }
        return nil // a number with no preceding command shouldn't happen at top level
    }
    var hasNumber: Bool {
        var j = i
        while j < s.count, s[j] == " " || s[j] == "," || s[j] == "\n" || s[j] == "\t" { j += 1 }
        guard j < s.count else { return false }
        let c = s[j]; return c == "-" || c == "+" || c == "." || c.isNumber
    }
    mutating func number() -> CGFloat {
        skipSep()
        var str = ""
        var seenDot = false, seenExp = false
        if i < s.count, s[i] == "+" || s[i] == "-" { str.append(s[i]); i += 1 }
        while i < s.count {
            let c = s[i]
            if c.isNumber { str.append(c); i += 1 }
            else if c == "." && !seenDot && !seenExp { seenDot = true; str.append(c); i += 1 }
            else if (c == "e" || c == "E") && !seenExp { seenExp = true; str.append(c); i += 1
                if i < s.count, s[i] == "+" || s[i] == "-" { str.append(s[i]); i += 1 } }
            else { break }
        }
        return CGFloat(Double(str) ?? 0)
    }
    mutating func flag() -> Bool {       // SVG arc flags are a single '0' or '1'
        skipSep()
        guard i < s.count else { return false }
        let c = s[i]; i += 1; return c == "1"
    }
    mutating func point() -> CGPoint { let x = number(); let y = number(); return CGPoint(x: x, y: y) }
}

/// SVG elliptical-arc → cubic Béziers (endpoint→center parameterization, ≤90° segments).
private enum SVGArc {
    static func append(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                       rx rxIn: CGFloat, ry ryIn: CGFloat, xAxisRotationDeg: CGFloat,
                       largeArc: Bool, sweep: Bool) {
        if rxIn == 0 || ryIn == 0 || p0 == p1 { path.addLine(to: p1); return }
        var rx = abs(rxIn), ry = abs(ryIn)
        let phi = xAxisRotationDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy, y1p = -sinP * dx + cosP * dy
        var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s; lambda = 1 }
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p)
        let den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
        let co = sign * sqrt(den == 0 ? 0 : num / den)
        let cxp = co * (rx * y1p / ry), cyp = co * (-ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux*vx + uy*vy, len = sqrt((ux*ux+uy*uy)*(vx*vx+vy*vy))
            var a = acos(max(-1, min(1, dot / (len == 0 ? 1 : len))))
            if ux*vy - uy*vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp)/rx, (y1p - cyp)/ry)
        var dTheta = angle((x1p - cxp)/rx, (y1p - cyp)/ry, (-x1p - cxp)/rx, (-y1p - cyp)/ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segs)
        let t = 4.0/3.0 * tan(delta/4)
        var ang = theta1
        for _ in 0..<segs {
            let cos1 = cos(ang), sin1 = sin(ang), cos2 = cos(ang + delta), sin2 = sin(ang + delta)
            func pt(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + (rx * c * cosP - ry * s * sinP), y: cy + (rx * c * sinP + ry * s * cosP))
            }
            let e1 = pt(cos1, sin1), e2 = pt(cos2, sin2)
            let c1 = CGPoint(x: e1.x - t * (rx * sin1 * cosP + ry * cos1 * sinP),
                             y: e1.y - t * (rx * sin1 * sinP - ry * cos1 * cosP))
            let c2 = CGPoint(x: e2.x + t * (rx * sin2 * cosP + ry * cos2 * sinP),
                             y: e2.y + t * (rx * sin2 * sinP - ry * cos2 * cosP))
            path.addCurve(to: e2, control1: c1, control2: c2)
            ang += delta
        }
    }
}

/// A Shape that renders an icon's `d` string scaled from the 24-grid into its rect.
struct SVGShape: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        let base = Path(svgPath: d)
        let sx = rect.width / 24, sy = rect.height / 24
        return base.applying(CGAffineTransform(scaleX: sx, y: sy))
    }
}

/// The design's line icon. Strokes by default (round caps/joins, 1.85pt); `filled` fills instead.
struct Icon: View {
    let name: String
    var size: CGFloat = 22
    var color: Color = Palette.ink
    var lineWidth: CGFloat = 1.85
    var filled: Bool = false

    var body: some View {
        let shape = SVGShape(d: Icons.paths[name] ?? "")
        Group {
            if filled {
                shape.fill(color)
            } else {
                shape.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview("Icons") {
    let names = Array(Icons.paths.keys).sorted()
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
        ForEach(names, id: \.self) { Icon(name: $0, size: 26, color: Palette.ink) }
    }
    .padding()
    .background(Palette.cream)
}
#endif
