import CoreGraphics
import Foundation

struct Suggerimento: Identifiable {
    let a: Int
    let b: Int
    let controllo: Bool
    var id: String { "\(a)-\(b)" }
}

struct AngoloFS: Identifiable {
    let id: Int
    let gradi: Double
    var scarto: Double { gradi - (gradi > 180 ? 270 : 90) }
}

struct StatoStanza {
    var latiQuotati: Int
    var lati: Int
    var diagMisurate: Int
    var diagNecessarie: Int
    var bloccata: Bool
    var scarto: Double
    var fuoriSquadra: [AngoloFS]
    var avanzamento: Double {
        let tot = lati + diagNecessarie
        return tot == 0 ? 0 : Double(latiQuotati + min(diagMisurate, diagNecessarie)) / Double(tot)
    }
}

enum Risolutore {
    private struct Vincolo { let i: Int; let j: Int; let l: Double; let w: Double }

    /// Sposta i vertici perché rispettino le misure prese (minimi quadrati, Gauss–Newton).
    /// Restituisce lo scarto massimo rimasto sulle misure, in metri.
    @discardableResult
    static func risolvi(_ s: inout Stanza) -> Double {
        let n = s.n
        guard n >= 3 else { return 0 }
        var vinc: [Vincolo] = []
        for i in 0..<n {
            if let m = s.lati[i].lunghezza.misurato {
                vinc.append(Vincolo(i: i, j: (i + 1) % n, l: m, w: 1))
            } else {
                vinc.append(Vincolo(i: i, j: (i + 1) % n, l: s.lunghezzaGeom(i), w: 0.02))
            }
        }
        for d in s.diagonali where d.a < n && d.b < n {
            vinc.append(Vincolo(i: d.a, j: d.b, l: d.misurato, w: 1))
        }
        guard vinc.contains(where: { $0.w == 1 }) else { s.aggiornaStime(); return 0 }

        let p0 = s.punti.flatMap { [Double($0.x), Double($0.y)] }
        var x = p0
        let m = 2 * n
        let ancora = 0.002
        for _ in 0..<80 {
            var A = Array(repeating: Array(repeating: 0.0, count: m), count: m)
            var g = Array(repeating: 0.0, count: m)
            for v in vinc {
                let dx = x[2 * v.i] - x[2 * v.j], dy = x[2 * v.i + 1] - x[2 * v.j + 1]
                let L = max(hypot(dx, dy), 1e-9)
                let r = L - v.l
                let J: [(Int, Double)] = [(2 * v.i, dx / L), (2 * v.i + 1, dy / L), (2 * v.j, -dx / L), (2 * v.j + 1, -dy / L)]
                for (a, ja) in J {
                    g[a] += v.w * ja * r
                    for (b, jb) in J { A[a][b] += v.w * ja * jb }
                }
            }
            for k in 0..<m {
                A[k][k] += ancora + 1e-9
                g[k] += ancora * (x[k] - p0[k])
            }
            guard let dxv = gauss(A, g.map { -$0 }) else { break }
            var mx = 0.0
            for k in 0..<m {
                x[k] += dxv[k]
                mx = max(mx, abs(dxv[k]))
            }
            if mx < 1e-8 { break }
        }
        s.punti = (0..<n).map { CGPoint(x: x[2 * $0], y: x[2 * $0 + 1]) }
        s.aggiornaStime()
        return scarto(s)
    }

    static func scarto(_ s: Stanza) -> Double {
        var mx = 0.0
        for i in 0..<s.n {
            if let m = s.lati[i].lunghezza.misurato { mx = max(mx, abs(s.lunghezzaGeom(i) - m)) }
        }
        for d in s.diagonali where d.a < s.n && d.b < s.n {
            mx = max(mx, abs(s.distanza(d.a, d.b) - d.misurato))
        }
        return mx
    }

    private static func gauss(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        let n = b.count
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<n where abs(A[r][c]) > abs(A[p][c]) { p = r }
            if abs(A[p][c]) < 1e-14 { return nil }
            if p != c { A.swapAt(p, c); b.swapAt(p, c) }
            for r in (c + 1)..<n {
                let f = A[r][c] / A[c][c]
                if f == 0 { continue }
                for k in c..<n { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = Array(repeating: 0.0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n { s -= A[r][k] * x[k] }
            x[r] = s / A[r][r]
        }
        return x
    }

    static func diagonaleValida(_ s: Stanza, _ i: Int, _ j: Int) -> Bool {
        let n = s.n
        if i == j || (i + 1) % n == j || (j + 1) % n == i { return false }
        let A = s.punti[i], B = s.punti[j]
        guard Geo.dentro(.medio(A, B), s.punti) else { return false }
        for k in 0..<n {
            let k2 = (k + 1) % n
            if k == i || k == j || k2 == i || k2 == j { continue }
            if Geo.incrocia(A, B, s.punti[k], s.punti[k2]) { return false }
        }
        return true
    }

    /// Quanti arredi rilevati stanno sulla linea della diagonale (il laser non passerebbe).
    static func arrediSullaLinea(_ s: Stanza, _ A: CGPoint, _ B: CGPoint) -> Int {
        s.ostacoli.filter { o in
            let c = o.angoli
            return (1..<20).contains { k in Geo.dentro(.lerp(A, B, CGFloat(k) / 20), c) }
        }.count
    }

    /// Diagonali da misurare: n-3 per bloccare la forma (una triangolazione) + una di controllo.
    /// Preferisce quelle corte e libere da arredi.
    static func diagonaliDaMisurare(_ s: Stanza) -> [Suggerimento] {
        let n = s.n
        guard n >= 4 else { return [] }
        let misurate = s.diagonali.filter { $0.a < n && $0.b < n }.map { ($0.a, $0.b) }
        func stessa(_ x: (Int, Int), _ y: (Int, Int)) -> Bool {
            (x.0 == y.0 && x.1 == y.1) || (x.0 == y.1 && x.1 == y.0)
        }
        var cand: [(Int, Int, Double)] = []
        for i in 0..<n {
            var j = i + 2
            while j < n {
                if diagonaleValida(s, i, j), !misurate.contains(where: { stessa($0, (i, j)) }) {
                    let A = s.punti[i], B = s.punti[j]
                    cand.append((i, j, Double(A.dist(B)) + 100 * Double(arrediSullaLinea(s, A, B))))
                }
                j += 1
            }
        }
        cand.sort { $0.2 < $1.2 }
        var scelte = misurate
        var out: [Suggerimento] = []
        var mancano = max(0, n - 3 - misurate.count)
        for c in cand where mancano > 0 {
            let A = s.punti[c.0], B = s.punti[c.1]
            let incrocia = scelte.contains { d in Geo.incrocia(A, B, s.punti[d.0], s.punti[d.1]) }
            if !incrocia {
                scelte.append((c.0, c.1))
                out.append(Suggerimento(a: c.0, b: c.1, controllo: false))
                mancano -= 1
            }
        }
        if misurate.count < n - 2,
           let c = cand.first(where: { c in !scelte.contains { stessa($0, (c.0, c.1)) } }) {
            out.append(Suggerimento(a: c.0, b: c.1, controllo: true))
        }
        return out
    }

    static func stato(_ s: Stanza) -> StatoStanza {
        let n = s.n
        let lq = s.lati.filter { $0.lunghezza.quotato }.count
        let dm = s.diagonali.count
        let nec = max(0, n - 3)
        let bloccata = n >= 3 && lq == n && dm >= nec
        var fs: [AngoloFS] = []
        if bloccata {
            for i in 0..<n {
                let a = AngoloFS(id: i, gradi: Geo.angoloInterno(s.punti, i))
                if abs(a.scarto) > 0.2 && abs(a.scarto) < 15 { fs.append(a) }
            }
        }
        return StatoStanza(latiQuotati: lq, lati: n, diagMisurate: dm, diagNecessarie: nec,
                           bloccata: bloccata, scarto: scarto(s), fuoriSquadra: fs)
    }
}
