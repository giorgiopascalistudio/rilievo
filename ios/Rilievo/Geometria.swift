import CoreGraphics
import Foundation

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var lunghezza: CGFloat { hypot(x, y) }
    var versore: CGPoint { let l = lunghezza; return l > 1e-9 ? CGPoint(x: x / l, y: y / l) : .zero }
    func dot(_ b: CGPoint) -> CGFloat { x * b.x + y * b.y }
    func cross(_ b: CGPoint) -> CGFloat { x * b.y - y * b.x }
    func dist(_ b: CGPoint) -> CGFloat { (self - b).lunghezza }
    static func medio(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { a + (b - a) * t }
}

enum Geo {
    /// Area con segno (formula di Gauss).
    static func area(_ p: [CGPoint]) -> CGFloat {
        guard p.count > 2 else { return 0 }
        var s: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    static func dentro(_ q: CGPoint, _ p: [CGPoint]) -> Bool {
        guard p.count > 2 else { return false }
        var c = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    static func centroide(_ p: [CGPoint]) -> CGPoint {
        let A = area(p)
        guard abs(A) > 1e-9 else {
            let n = CGFloat(max(p.count, 1))
            return CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
        }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            let f = a.x * b.y - b.x * a.y
            cx += (a.x + b.x) * f
            cy += (a.y + b.y) * f
        }
        return CGPoint(x: cx / (6 * A), y: cy / (6 * A))
    }

    static func riquadro(_ p: [CGPoint]) -> CGRect {
        guard let f = p.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for q in p { r = r.union(CGRect(origin: q, size: .zero)) }
        return r
    }

    /// Distanza di q dal segmento ab e parametro 0...1 del piede della perpendicolare.
    static func distSegmento(_ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (d: CGFloat, t: CGFloat) {
        let ab = b - a
        let l2 = ab.dot(ab)
        guard l2 > 1e-12 else { return (q.dist(a), 0) }
        let t = max(0, min(1, (q - a).dot(ab) / l2))
        return (q.dist(a + ab * t), t)
    }

    /// Vero se i segmenti ab e cd si incrociano all'interno (estremi comuni esclusi).
    static func incrocia(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let e: CGFloat = 1e-9
        let d1 = (b - a).cross(c - a), d2 = (b - a).cross(d - a)
        let d3 = (d - c).cross(a - c), d4 = (d - c).cross(b - c)
        return ((d1 > e && d2 < -e) || (d1 < -e && d2 > e)) && ((d3 > e && d4 < -e) || (d3 < -e && d4 > e))
    }

    /// Intersezione di due rette (punto + direzione unitaria). Nil se quasi parallele.
    static func intersezione(_ p1: CGPoint, _ d1: CGPoint, _ p2: CGPoint, _ d2: CGPoint) -> CGPoint? {
        let den = d1.cross(d2)
        guard abs(den) > 0.03 else { return nil }
        let t = (p2 - p1).cross(d2) / den
        return p1 + d1 * t
    }

    static func normaleEsterna(_ p: [CGPoint], _ i: Int) -> CGPoint {
        let d = (p[(i + 1) % p.count] - p[i]).versore
        return area(p) > 0 ? CGPoint(x: d.y, y: -d.x) : CGPoint(x: -d.y, y: d.x)
    }

    /// Filo esterno dei muri: ogni lato spostato verso l'esterno del suo spessore.
    static func contornoEsterno(_ p: [CGPoint], _ sp: [CGFloat]) -> [CGPoint] {
        let n = p.count
        guard n > 2, sp.count == n else { return p }
        return (0..<n).map { i in
            let h = (i - 1 + n) % n
            let nh = normaleEsterna(p, h), ni = normaleEsterna(p, i)
            let a = p[h] + nh * sp[h], b = p[i] + ni * sp[i]
            let dh = (p[i] - p[h]).versore, di = (p[(i + 1) % n] - p[i]).versore
            if let x = intersezione(a, dh, b, di), x.dist(p[i]) < 3 * max(sp[h], sp[i]) + 0.05 { return x }
            return b
        }
    }

    /// Angolo interno in gradi (0...360) nel vertice i.
    static func angoloInterno(_ p: [CGPoint], _ i: Int) -> Double {
        let n = p.count
        guard n > 2 else { return 0 }
        let a = p[(i - 1 + n) % n], b = p[i], c = p[(i + 1) % n]
        let u = (a - b).versore, v = (c - b).versore
        let ang = Double(acos(max(-1, min(1, u.dot(v))))) * 180 / .pi
        let giro = (b - a).cross(c - b)
        let convesso = area(p) > 0 ? giro > 0 : giro < 0
        return convesso ? ang : 360 - ang
    }

    /// Semplificazione di Ramer–Douglas–Peucker.
    static func rdp(_ p: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var dmax: CGFloat = 0
        var idx = 0
        for i in 1..<(p.count - 1) {
            let d = distSegmento(p[i], p[0], p[p.count - 1]).d
            if d > dmax { dmax = d; idx = i }
        }
        if dmax > eps {
            let a = rdp(Array(p[0...idx]), eps)
            let b = rdp(Array(p[idx...]), eps)
            return Array(a.dropLast()) + b
        }
        return [p[0], p[p.count - 1]]
    }

    private struct Retta { var m: CGPoint; var d: CGPoint; var l: CGFloat }

    /// Trasforma uno schizzo a mano libera in un poligono a lati dritti:
    /// semplifica, aggancia gli angoli a multipli di 45° rispetto all'asse e unisce i tratti allineati.
    static func raddrizza(_ tratto: [CGPoint], eps: CGFloat, chiusura: CGFloat, asse: Double?, tolleranza: Double = 12) -> [CGPoint]? {
        guard tratto.count > 4 else { return nil }
        let box = riquadro(tratto)
        let diag = hypot(box.width, box.height)
        guard diag > chiusura * 1.5 else { return nil }
        var pts = rdp(tratto, eps)
        guard let f = pts.first, let l = pts.last else { return nil }
        if f.dist(l) < max(chiusura, diag * 0.25) { pts.removeLast() } else { return nil }
        guard pts.count >= 3 else { return nil }
        let n = pts.count
        var rette: [Retta] = (0..<n).map { i in
            let a = pts[i], b = pts[(i + 1) % n]
            return Retta(m: .medio(a, b), d: (b - a).versore, l: a.dist(b))
        }
        rette.removeAll { $0.l < 1e-6 }
        guard let lunga = rette.max(by: { $0.l < $1.l }) else { return nil }
        let rif = asse ?? Double(atan2(lunga.d.y, lunga.d.x))
        for k in rette.indices {
            let th = Double(atan2(rette[k].d.y, rette[k].d.x))
            var rel = (th - rif) * 180 / .pi
            rel = rel.truncatingRemainder(dividingBy: 360)
            if rel < 0 { rel += 360 }
            let s = (rel / 45).rounded() * 45
            if abs(rel - s) < tolleranza {
                let nuovo = rif + s * .pi / 180
                rette[k].d = CGPoint(x: cos(nuovo), y: sin(nuovo))
            }
        }
        var cambiato = true
        while cambiato && rette.count > 3 {
            cambiato = false
            for k in rette.indices {
                let j = (k + 1) % rette.count
                if abs(rette[k].d.cross(rette[j].d)) < 0.02 {
                    let a = rette[k], b = rette[j]
                    let L = a.l + b.l
                    let m = CGPoint(x: (a.m.x * a.l + b.m.x * b.l) / L, y: (a.m.y * a.l + b.m.y * b.l) / L)
                    rette[k] = Retta(m: m, d: a.l >= b.l ? a.d : b.d, l: L)
                    rette.remove(at: j)
                    cambiato = true
                    break
                }
            }
        }
        guard rette.count >= 3 else { return nil }
        let m = rette.count
        var out: [CGPoint] = []
        for k in 0..<m {
            let h = rette[(k - 1 + m) % m], r = rette[k]
            if let x = intersezione(h.m, h.d, r.m, r.d), x.dist(r.m) < diag * 1.5 {
                out.append(x)
            } else {
                out.append(.medio(h.m + h.d * (h.l / 2), r.m - r.d * (r.l / 2)))
            }
        }
        return abs(area(out)) > 1e-4 ? out : nil
    }

    /// Toglie vertici quasi doppi o su lati allineati.
    static func pulisci(_ p: [CGPoint]) -> [CGPoint] {
        var q = p
        var cambiato = true
        while cambiato && q.count > 3 {
            cambiato = false
            for i in q.indices {
                let n = q.count
                let a = q[(i - 1 + n) % n], b = q[i], c = q[(i + 1) % n]
                let u = (b - a).versore, v = (c - b).versore
                if a.dist(b) < 0.04 || (abs(u.cross(v)) < 0.05 && u.dot(v) > 0) {
                    q.remove(at: i)
                    cambiato = true
                    break
                }
            }
        }
        return q
    }

    static func angoloLeggibile(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        var t = atan2(b.y - a.y, b.x - a.x)
        if t > .pi / 2 { t -= .pi } else if t < -.pi / 2 { t += .pi }
        return t
    }
}

enum Fmt {
    static func m(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        if s.hasSuffix("0") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }
    static func cm(_ v: Double) -> String {
        String(format: "%.1f cm", v * 100).replacingOccurrences(of: ".", with: ",")
    }
    static func cmIntero(_ v: Double) -> String { String(format: "%.0f", v * 100) }
    static func gradi(_ v: Double) -> String {
        String(format: "%.1f°", v).replacingOccurrences(of: ".", with: ",")
    }
    static func area(_ v: Double) -> String {
        String(format: "%.2f m²", v).replacingOccurrences(of: ".", with: ",")
    }
    /// Accetta "3,42", "3.42" o "342" (oltre `maxMetri` il numero si intende in centimetri).
    static func numero(_ testo: String, maxMetri: Double) -> Double? {
        let t = testo.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v >= 0 else { return nil }
        return v > maxMetri ? v / 100 : v
    }
}
