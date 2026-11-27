import CoreGraphics
import Foundation
import simd

/// Dalla nuvola di punti LiDAR di una stanza a una pianta semplificata:
/// pavimento/soffitto dall'istogramma delle quote, pareti come linee (RANSAC) in una fetta
/// orizzontale sopra gli arredi, perimetro chiuso visto dal percorso della scansione,
/// aperture dai vuoti lungo le pareti, arredi come ingombri.
enum Semplifica {
    struct Esito {
        var stanza: Stanza
        var pareti: Int
        var aperture: Int
    }

    private struct Segmento {
        var p: CGPoint   // punto sulla retta
        var d: CGPoint   // direzione unitaria
        var t0: CGFloat
        var t1: CGFloat
        var lunghezza: CGFloat { t1 - t0 }
        var a: CGPoint { p + d * t0 }
        var b: CGPoint { p + d * t1 }
    }

    static func stanza(punti: [SIMD3<Float>], camere: [SIMD3<Float>], nome: String) -> Esito? {
        guard punti.count > 2000, !camere.isEmpty else { return nil }

        // 1. pavimento e soffitto
        let ys = punti.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max(), maxY - minY > 1.5 else { return nil }
        let passo: Float = 0.02
        let nb = Int((maxY - minY) / passo) + 1
        var isto = [Int](repeating: 0, count: nb)
        for y in ys { isto[min(nb - 1, Int((y - minY) / passo))] += 1 }
        let basso = Int(Float(nb) * 0.4), alto = Int(Float(nb) * 0.6)
        let iPav = (0..<max(1, basso)).max { isto[$0] < isto[$1] } ?? 0
        let iSof = (min(alto, nb - 1)..<nb).max { isto[$0] < isto[$1] } ?? (nb - 1)
        let pavimento = minY + (Float(iPav) + 0.5) * passo
        let ordinati = ys.sorted()
        let p99 = ordinati[Int(Float(ordinati.count - 1) * 0.995)]
        let soffittoPiano = isto[iSof] >= max(200, Int(Double(isto[iPav]) * 0.25))
        let quotaSoffitto = soffittoPiano ? minY + (Float(iSof) + 0.5) * passo : p99
        let hSoffitto = quotaSoffitto - pavimento
        guard hSoffitto > 1.6 else { return nil }

        // 2. fetta orizzontale sopra gli arredi bassi
        let lo = pavimento + 1.1
        let hi = max(lo + 0.4, min(pavimento + 2.1, quotaSoffitto - 0.15))
        var celle: [Int64: Int] = [:]
        let lato: Float = 0.02
        func chiave(_ x: Float, _ z: Float) -> Int64 {
            (Int64((x / lato).rounded(.down)) + 1_000_000) << 21 | (Int64((z / lato).rounded(.down)) + 1_000_000)
        }
        for p in punti where p.y > lo && p.y < hi { celle[chiave(p.x, p.z), default: 0] += 1 }
        var fetta: [CGPoint] = []
        for (k, c) in celle where c >= 2 {
            let ix = (k >> 21) - 1_000_000, iz = (k & 0x1F_FFFF) - 1_000_000
            fetta.append(CGPoint(x: (CGFloat(ix) + 0.5) * CGFloat(lato), y: (CGFloat(iz) + 0.5) * CGFloat(lato)))
        }
        guard fetta.count > 150 else { return nil }

        // 3. pareti con RANSAC
        var segmenti = ransac(fetta)
        guard segmenti.count >= 3 else { return nil }
        squadra(&segmenti)
        segmenti = unisciAllineati(segmenti)

        // 4. perimetro visto dal centro del percorso di scansione
        let cx = camere.map(\.x).reduce(0, +) / Float(camere.count)
        let cz = camere.map(\.z).reduce(0, +) / Float(camere.count)
        let centro = CGPoint(x: CGFloat(cx), y: CGFloat(cz))
        guard var poligono = perimetro(segmenti, da: centro), poligono.count >= 3 else { return nil }
        poligono = Geo.pulisci(poligono)
        guard poligono.count >= 3, abs(Geo.area(poligono)) > 1 else { return nil }

        var s = Stanza.nuova(nome: nome, punti: poligono)
        s.origine = "nuvola"

        // 5. soffitto
        if soffittoPiano {
            s.soffitto.tipo = .piano
            s.soffitto.altezza = Quota(Double(hSoffitto))
        } else {
            s.soffitto.tipo = .botte
            s.soffitto.altezzaMax = Quota(Double(hSoffitto))
            s.soffitto.altezza = Quota(Double(impostaVolta(punti, s, pavimento: pavimento, chiave: quotaSoffitto)))
            s.soffitto.latoAsse = (0..<s.n).max { s.lunghezzaGeom($0) < s.lunghezzaGeom($1) } ?? 0
        }

        // 6. aperture dai vuoti lungo le pareti
        let altezzaUtile = (soffittoPiano ? hSoffitto : Float(s.soffitto.altezza.valore)) - 0.08
        s.aperture = aperture(punti, s, pavimento: pavimento, altezza: altezzaUtile)

        // 7. arredi come ingombri
        s.ostacoli = ingombri(punti, s, pavimento: pavimento)

        // 8. traccia da mostrare sotto la pianta
        s.traccia = diradata(fetta, passo: 0.03, massimo: 9000)
        return Esito(stanza: s, pareti: s.n, aperture: s.aperture.count)
    }

    // MARK: - RANSAC

    private static func ransac(_ tutti: [CGPoint]) -> [Segmento] {
        var resto = tutti
        var out: [Segmento] = []
        var rng = SystemRandomNumberGenerator()
        let soglia: CGFloat = 0.025
        while out.count < 40 && resto.count > 40 {
            var migliore: (p: CGPoint, d: CGPoint, n: Int)?
            for _ in 0..<500 {
                let a = resto[Int.random(in: 0..<resto.count, using: &rng)]
                let b = resto[Int.random(in: 0..<resto.count, using: &rng)]
                let l = a.dist(b)
                guard l > 0.2, l < 4 else { continue }
                let d = (b - a).versore
                let nrm = CGPoint(x: -d.y, y: d.x)
                var c = 0
                for q in resto where abs((q - a).dot(nrm)) < soglia { c += 1 }
                if migliore == nil || c > migliore!.n { migliore = (a, d, c) }
            }
            guard let m = migliore, m.n >= 30 else { break }
            // rifinitura ai minimi quadrati (direzione principale degli inlier)
            let nrm0 = CGPoint(x: -m.d.y, y: m.d.x)
            let inl = resto.filter { abs(($0 - m.p).dot(nrm0)) < soglia }
            let (p, d) = pca(inl)
            let nrm = CGPoint(x: -d.y, y: d.x)
            let vicini = resto.filter { abs(($0 - p).dot(nrm)) < soglia * 1.2 }
            resto.removeAll { abs(($0 - p).dot(nrm)) < soglia * 1.2 }
            // tratti continui lungo la retta
            let ts = vicini.map { ($0 - p).dot(d) }.sorted()
            var inizio = ts.first ?? 0
            var prec = inizio
            var conta = 0
            func chiudi(_ fine: CGFloat) {
                let L = fine - inizio
                if L >= 0.35 && CGFloat(conta) * 0.02 / L > 0.25 { out.append(Segmento(p: p, d: d, t0: inizio, t1: fine)) }
            }
            for t in ts {
                if t - prec > 0.3 { chiudi(prec); inizio = t; conta = 0 }
                prec = t
                conta += 1
            }
            chiudi(prec)
        }
        return out
    }

    private static func pca(_ q: [CGPoint]) -> (CGPoint, CGPoint) {
        let n = CGFloat(max(q.count, 1))
        let m = CGPoint(x: q.map(\.x).reduce(0, +) / n, y: q.map(\.y).reduce(0, +) / n)
        var sxx: CGFloat = 0, sxy: CGFloat = 0, syy: CGFloat = 0
        for p in q {
            let d = p - m
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y
        }
        let ang = 0.5 * atan2(2 * sxy, sxx - syy)
        return (m, CGPoint(x: cos(ang), y: sin(ang)))
    }

    /// Porta a 90° esatti le pareti quasi in squadra con la direzione dominante.
    private static func squadra(_ s: inout [Segmento]) {
        var isto = [CGFloat](repeating: 0, count: 90)
        for g in s {
            var a = atan2(g.d.y, g.d.x) * 180 / .pi
            a = a.truncatingRemainder(dividingBy: 90); if a < 0 { a += 90 }
            isto[min(89, Int(a))] += g.lunghezza
        }
        var best = 0
        var bestV: CGFloat = -1
        for i in 0..<90 {
            let v = isto[(i + 89) % 90] + isto[i] * 2 + isto[(i + 1) % 90]
            if v > bestV { bestV = v; best = i }
        }
        let dom = (CGFloat(best) + 0.5) * .pi / 180
        for k in s.indices {
            let a = atan2(s[k].d.y, s[k].d.x)
            let rel = a - dom
            let q = (rel / (.pi / 2)).rounded() * (.pi / 2)
            if abs(rel - q) < 4 * .pi / 180 {
                let mid = s[k].p + s[k].d * ((s[k].t0 + s[k].t1) / 2)
                let L = s[k].lunghezza
                let nd = CGPoint(x: cos(dom + q), y: sin(dom + q))
                s[k] = Segmento(p: mid, d: nd, t0: -L / 2, t1: L / 2)
            }
        }
    }

    /// Unisce i tratti sulla stessa retta (una parete interrotta da porte o finestre).
    private static func unisciAllineati(_ s: [Segmento]) -> [Segmento] {
        var r = s.sorted { $0.lunghezza > $1.lunghezza }
        var i = 0
        while i < r.count {
            var j = i + 1
            while j < r.count {
                let a = r[i], b = r[j]
                let par = abs(a.d.cross(b.d)) < 0.035
                let nrm = CGPoint(x: -a.d.y, y: a.d.x)
                if par && abs((b.p - a.p).dot(nrm)) < 0.05 {
                    let tb0 = (b.a - a.p).dot(a.d), tb1 = (b.b - a.p).dot(a.d)
                    let lunghi = a.lunghezza + b.lunghezza
                    let t0 = min(a.t0, tb0, tb1), t1 = max(a.t1, tb0, tb1)
                    if t1 - t0 < lunghi + 2.5 {
                        r[i].t0 = t0
                        r[i].t1 = t1
                        r.remove(at: j)
                        continue
                    }
                }
                j += 1
            }
            i += 1
        }
        return r
    }

    // MARK: - perimetro

    private static func perimetro(_ s: [Segmento], da c: CGPoint) -> [CGPoint]? {
        let raggi = 720
        var ids: [Int] = []
        var colpi: [CGPoint] = []
        for k in 0..<raggi {
            let a = CGFloat(k) / CGFloat(raggi) * 2 * .pi
            let r = CGPoint(x: cos(a), y: sin(a))
            var best: (Int, CGFloat)?
            for (i, g) in s.enumerated() {
                let den = r.cross(g.d)
                guard abs(den) > 1e-6 else { continue }
                let w = g.a - c
                let tr = w.cross(g.d) / den
                let tg = w.cross(r) / den
                guard tr > 0.05, tr < 15, tg > -0.08, tg < g.lunghezza + 0.08 else { continue }
                if best == nil || tr < best!.1 { best = (i, tr) }
            }
            if let b = best {
                ids.append(b.0)
                colpi.append(c + r * b.1)
            }
        }
        guard !ids.isEmpty else { return nil }
        // sequenze di raggi sulla stessa parete
        var corse: [(id: Int, n: Int, primo: CGPoint, ultimo: CGPoint)] = []
        for (k, id) in ids.enumerated() {
            if let u = corse.last, u.id == id {
                corse[corse.count - 1].n += 1
                corse[corse.count - 1].ultimo = colpi[k]
            } else {
                corse.append((id, 1, colpi[k], colpi[k]))
            }
        }
        if corse.count > 1, corse.first!.id == corse.last!.id {
            let u = corse.removeLast()
            corse[0].n += u.n
            corse[0].primo = u.primo
        }
        corse.removeAll { $0.n < 4 && s[$0.id].lunghezza < 0.8 }
        var fuse: [(id: Int, n: Int, primo: CGPoint, ultimo: CGPoint)] = []
        for c in corse {
            if let u = fuse.last, u.id == c.id {
                fuse[fuse.count - 1].ultimo = c.ultimo
            } else {
                fuse.append(c)
            }
        }
        if fuse.count > 1, fuse.first!.id == fuse.last!.id { fuse.removeLast() }
        guard fuse.count >= 3 else { return nil }

        var out: [CGPoint] = []
        let m = fuse.count
        for k in 0..<m {
            let h = s[fuse[(k - 1 + m) % m].id], g = s[fuse[k].id]
            if let x = Geo.intersezione(h.p, h.d, g.p, g.d), x.dist(fuse[k].primo) < 3 {
                out.append(x)
            } else {
                // pareti parallele: gradino nascosto, lo chiudo con due vertici
                let fine = fuse[(k - 1 + m) % m].ultimo, inizio = fuse[k].primo
                out.append(h.p + h.d * (fine - h.p).dot(h.d))
                out.append(g.p + g.d * (inizio - g.p).dot(g.d))
            }
        }
        return out
    }

    // MARK: - soffitto a volta

    private static func impostaVolta(_ punti: [SIMD3<Float>], _ s: Stanza, pavimento: Float, chiave: Float) -> Float {
        // quota più alta raggiunta dai punti vicini alle pareti: lì la volta "nasce"
        var massimi: [Float] = []
        for i in 0..<s.n {
            let A = s.punti[i], B = s.punti[(i + 1) % s.n]
            let u = (B - A).versore, nrm = CGPoint(x: -u.y, y: u.x)
            let L = A.dist(B)
            var alti: [Float] = []
            for p in punti {
                let q = CGPoint(x: CGFloat(p.x), y: CGFloat(p.z)) - A
                let t = q.dot(u)
                if t > 0.2, t < L - 0.2, abs(q.dot(nrm)) < 0.05 { alti.append(p.y) }
            }
            if alti.count > 50 {
                alti.sort()
                massimi.append(alti[Int(Float(alti.count - 1) * 0.97)])
            }
        }
        guard !massimi.isEmpty else { return (chiave - pavimento) * 0.75 }
        massimi.sort()
        return min(massimi[massimi.count / 2], chiave - 0.1) - pavimento
    }

    // MARK: - aperture

    private static func aperture(_ punti: [SIMD3<Float>], _ s: Stanza, pavimento: Float, altezza: Float) -> [Apertura] {
        var out: [Apertura] = []
        let col: CGFloat = 0.05
        let bin: Float = 0.05
        let nh = max(10, Int(altezza / bin))
        for i in 0..<s.n {
            let A = s.punti[i], B = s.punti[(i + 1) % s.n]
            let L = A.dist(B)
            guard L > 0.6 else { continue }
            let u = (B - A).versore, nrm = CGPoint(x: -u.y, y: u.x)
            let nc = Int(L / col)
            var griglia = [[Bool]](repeating: [Bool](repeating: false, count: nh), count: nc)
            for p in punti {
                let q = CGPoint(x: CGFloat(p.x), y: CGFloat(p.z)) - A
                guard abs(q.dot(nrm)) < 0.07 else { continue }
                let t = q.dot(u)
                guard t >= 0, t < L else { continue }
                let h = p.y - pavimento
                guard h >= 0, h < altezza else { continue }
                griglia[min(nc - 1, Int(t / col))][min(nh - 1, Int(h / bin))] = true
            }
            // classifico ogni colonna: 1 porta, 2 finestra, 0 pieno, -1 ignota
            var classe = [Int](repeating: 0, count: nc)
            var basi = [Float](repeating: 0, count: nc), alte = [Float](repeating: 0, count: nc)
            for c in 0..<nc {
                let g = griglia[c]
                if g.filter({ $0 }).count < 4 { classe[c] = -1; continue }
                var best = (inizio: 0, n: 0)
                var k = 0
                while k < nh {
                    if !g[k] {
                        var e = k
                        while e < nh && !g[e] { e += 1 }
                        if e - k > best.n { best = (k, e - k) }
                        k = e
                    } else { k += 1 }
                }
                let b0 = Float(best.inizio) * bin, hh = Float(best.n) * bin
                basi[c] = b0; alte[c] = hh
                if b0 < 0.15 && hh > 1.7 { classe[c] = 1 } else if b0 > 0.3 && b0 < 1.4 && hh > 0.5 { classe[c] = 2 }
            }
            var c = 0
            while c < nc {
                let k = classe[c]
                guard k > 0 else { c += 1; continue }
                var e = c
                while e < nc && (classe[e] == k || (e + 1 < nc && classe[e + 1] == k && classe[e] != 0)) { e += 1 }
                let w = Double(CGFloat(e - c) * col)
                if w >= 0.5 && w < 4 {
                    let b = Array(basi[c..<e]).sorted(), h = Array(alte[c..<e]).sorted()
                    let dav = Double(k == 1 ? 0 : b[b.count / 2])
                    let alt = Double(h[h.count / 2])
                    var tipo: TipoApertura = k == 1 ? .porta : .finestra
                    if k == 1 && alt > 2.25 && w > 1.0 { tipo = .portafinestra }
                    out.append(Apertura(tipo: tipo, lato: i, distanza: Quota(Double(CGFloat(c) * col)), larghezza: Quota(w),
                                        altezza: Quota(alt), davanzale: Quota(dav)))
                }
                c = e
            }
        }
        return out
    }

    // MARK: - arredi

    private static func ingombri(_ punti: [SIMD3<Float>], _ s: Stanza, pavimento: Float) -> [Ostacolo] {
        let lato: CGFloat = 0.1
        var celle = Set<Int64>()
        func k(_ ix: Int, _ iz: Int) -> Int64 { Int64(ix + 100_000) << 20 | Int64(iz + 100_000) }
        for p in punti {
            let h = p.y - pavimento
            guard h > 0.15, h < 1.0 else { continue }
            let q = CGPoint(x: CGFloat(p.x), y: CGFloat(p.z))
            guard Geo.dentro(q, s.punti) else { continue }
            var vicino = false
            for i in 0..<s.n where Geo.distSegmento(q, s.punti[i], s.punti[(i + 1) % s.n]).d < 0.12 { vicino = true; break }
            if vicino { continue }
            celle.insert(k(Int((q.x / lato).rounded(.down)), Int((q.y / lato).rounded(.down))))
        }
        var visti = Set<Int64>()
        var out: [Ostacolo] = []
        for c in celle where !visti.contains(c) {
            var coda = [c]
            visti.insert(c)
            var minX = Int.max, maxX = Int.min, minZ = Int.max, maxZ = Int.min
            var n = 0
            while let x = coda.popLast() {
                let ix = Int(x >> 20) - 100_000, iz = Int(x & 0xF_FFFF) - 100_000
                minX = min(minX, ix); maxX = max(maxX, ix); minZ = min(minZ, iz); maxZ = max(maxZ, iz)
                n += 1
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let v = k(ix + dx, iz + dz)
                    if celle.contains(v) && !visti.contains(v) { visti.insert(v); coda.append(v) }
                }
            }
            guard n >= 8 else { continue }
            let w = Double(maxX - minX + 1) * Double(lato), h = Double(maxZ - minZ + 1) * Double(lato)
            let centro = CGPoint(x: (CGFloat(minX + maxX + 1) / 2) * lato, y: (CGFloat(minZ + maxZ + 1) / 2) * lato)
            out.append(Ostacolo(centro: centro, w: w, h: h, angolo: 0, nome: "ingombro"))
        }
        return out
    }

    static func diradata(_ p: [CGPoint], passo: CGFloat, massimo: Int) -> [CGPoint] {
        var visti = Set<Int64>()
        var out: [CGPoint] = []
        for q in p {
            let key = Int64((q.x / passo).rounded(.down) + 1_000_000) << 21 | Int64((q.y / passo).rounded(.down) + 1_000_000)
            if visti.insert(key).inserted { out.append(q) }
        }
        if out.count > massimo {
            let k = Double(out.count) / Double(massimo)
            return (0..<massimo).map { out[Int(Double($0) * k)] }
        }
        return out
    }
}
