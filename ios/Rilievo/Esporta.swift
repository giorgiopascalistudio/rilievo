import CoreGraphics
import Foundation

/// DXF R12 (ASCII, metri) con layer separati: MURI, APERTURE, QUOTE, DIAGONALI, TESTI, ALTEZZE.
/// Gli arredi rilevati dal LiDAR non vengono esportati.
struct DXF {
    private var corpo = ""

    private func f(_ v: CGFloat) -> String { String(format: "%.4f", Double(v)) }
    private mutating func g(_ c: Int, _ v: String) { corpo += "\(c)\n\(v)\n" }

    mutating func linea(_ a: CGPoint, _ b: CGPoint, _ layer: String) {
        g(0, "LINE"); g(8, layer)
        g(10, f(a.x)); g(20, f(-a.y)); g(30, "0.0")
        g(11, f(b.x)); g(21, f(-b.y)); g(31, "0.0")
    }

    /// Arco da `da` a `a` attorno al centro c, per la via più corta.
    mutating func arco(_ c: CGPoint, da p: CGPoint, a q: CGPoint, _ layer: String) {
        let r = c.dist(p)
        let a0 = atan2(-(p.y - c.y), p.x - c.x) * 180 / .pi
        let a1 = atan2(-(q.y - c.y), q.x - c.x) * 180 / .pi
        var d = a1 - a0
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        let (s, e) = d > 0 ? (a0, a1) : (a1, a0)
        g(0, "ARC"); g(8, layer)
        g(10, f(c.x)); g(20, f(-c.y)); g(30, "0.0")
        g(40, f(r)); g(50, String(format: "%.4f", Double(s))); g(51, String(format: "%.4f", Double(e)))
    }

    mutating func testo(_ s: String, _ p: CGPoint, _ h: Double, _ layer: String, rot: Double = 0) {
        g(0, "TEXT"); g(8, layer)
        g(10, f(p.x)); g(20, f(-p.y)); g(30, "0.0")
        g(40, String(format: "%.4f", h)); g(1, s); g(50, String(format: "%.3f", rot))
        g(72, "1"); g(11, f(p.x)); g(21, f(-p.y)); g(31, "0.0"); g(73, "2")
    }

    func documento() -> String {
        let layer: [(String, Int)] = [("MURI", 7), ("APERTURE", 4), ("QUOTE", 3), ("QUOTE_STIMATE", 30),
                                      ("DIAGONALI", 1), ("TESTI", 7), ("ALTEZZE", 6)]
        var h = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$DWGCODEPAGE\n3\nANSI_1252\n9\n$INSUNITS\n70\n6\n0\nENDSEC\n"
        h += "0\nSECTION\n2\nTABLES\n"
        h += "0\nTABLE\n2\nLTYPE\n70\n1\n0\nLTYPE\n2\nCONTINUOUS\n70\n0\n3\nSolid line\n72\n65\n73\n0\n40\n0.0\n0\nENDTAB\n"
        h += "0\nTABLE\n2\nLAYER\n70\n\(layer.count)\n"
        for (n, c) in layer { h += "0\nLAYER\n2\n\(n)\n70\n0\n62\n\(c)\n6\nCONTINUOUS\n" }
        h += "0\nENDTAB\n0\nENDSEC\n"
        return h + "0\nSECTION\n2\nENTITIES\n" + corpo + "0\nENDSEC\n0\nEOF\n"
    }
}

enum Esporta {
    private static func gradiDXF(_ a: CGPoint, _ b: CGPoint) -> Double {
        // angolo leggibile nel sistema DXF (y verso l'alto)
        var t = atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
        if t > 90 { t -= 180 } else if t <= -90 { t += 180 }
        return Double(t)
    }

    static func dxf(_ r: Rilievo) -> String {
        var d = DXF()
        for s in r.stanze where s.n >= 3 { stanza(s, &d) }
        return d.documento()
    }

    private static func stanza(_ s: Stanza, _ d: inout DXF) {
        let n = s.n
        let P = s.punti
        let O = Geo.contornoEsterno(P, s.lati.map { CGFloat($0.spessore.valore) })
        for i in 0..<n {
            let j = (i + 1) % n
            let A = P[i], B = P[j]
            let L = s.lunghezzaGeom(i)
            let u = (B - A).versore
            let no = Geo.normaleEsterna(P, i)
            let t = CGFloat(s.lati[i].spessore.valore)
            let vani = s.aperture.filter { $0.lato == i }
                .map { (max(0, $0.distanza.valore), min(L, $0.distanza.valore + $0.larghezza.valore)) }
                .sorted { $0.0 < $1.0 }
            var cur = 0.0
            var pieni: [(Double, Double)] = []
            for (a, b) in vani {
                if a > cur { pieni.append((cur, a)) }
                cur = max(cur, b)
            }
            if cur < L { pieni.append((cur, L)) }
            for (a, b) in pieni {
                let pa = A + u * CGFloat(a), pb = A + u * CGFloat(b)
                d.linea(pa, pb, "MURI")
                let oa = a <= 1e-6 ? O[i] : pa + no * t
                let ob = b >= L - 1e-6 ? O[j] : pb + no * t
                d.linea(oa, ob, "MURI")
            }
            for (a, b) in vani {
                for x in [a, b] where x > 1e-6 && x < L - 1e-6 {
                    let q = A + u * CGFloat(x)
                    d.linea(q, q + no * t, "MURI")
                }
            }
            // quota del lato
            let q = s.lati[i].lunghezza
            let testo = q.quotato ? Fmt.m(q.misurato!) : "~" + Fmt.m(L)
            d.testo(testo, .medio(A, B) - no * 0.22, 0.12, q.quotato ? "QUOTE" : "QUOTE_STIMATE", rot: gradiDXF(A, B))
            d.testo(s.lettera(i), P[i] + (s.centro - P[i]).versore * 0.25, 0.10, "TESTI")
        }

        for a in s.aperture {
            guard let g = s.geometriaApertura(a) else { continue }
            let t = g.spessore
            if a.tipo == .finestra || a.tipo == .portafinestra {
                for f in [t / 3, 2 * t / 3] { d.linea(g.p1 + g.nOut * f, g.p2 + g.nOut * f, "APERTURE") }
            }
            if a.tipo.haAnta {
                let w = CGFloat(a.larghezza.valore)
                let cerniera = a.verso == 1 ? g.p1 : g.p2
                let chiusa = a.verso == 1 ? g.p2 : g.p1
                let dir = a.apreDentro ? g.nOut * -1 : g.nOut
                let base = a.apreDentro ? cerniera : cerniera + g.nOut * t
                let chiusaB = a.apreDentro ? chiusa : chiusa + g.nOut * t
                let foglia = base + dir * w
                d.linea(base, foglia, "APERTURE")
                d.arco(base, da: chiusaB, a: foglia, "APERTURE")
            }
            var etichetta = "\(a.tipo.sigla) \(Fmt.m(a.larghezza.valore))x\(Fmt.m(a.altezza.valore))"
            if a.davanzale.valore > 0.005 || a.tipo == .finestra { etichetta += " dav \(Fmt.m(a.davanzale.valore))" }
            if !a.completa { etichetta += " ~" }
            d.testo(etichetta, .medio(g.p1, g.p2) - g.nOut * 0.42, 0.09, "ALTEZZE", rot: gradiDXF(g.p1, g.p2))
        }

        for dg in s.diagonali where dg.a < n && dg.b < n {
            d.linea(P[dg.a], P[dg.b], "DIAGONALI")
            d.testo("\(s.lettera(dg.a))-\(s.lettera(dg.b)) \(Fmt.m(dg.misurato))", .medio(P[dg.a], P[dg.b]), 0.10,
                    "DIAGONALI", rot: gradiDXF(P[dg.a], P[dg.b]))
        }

        let c = s.centro
        d.testo(s.nome, c - CGPoint(x: 0, y: 0.25), 0.20, "TESTI")
        d.testo(Fmt.area(s.area).replacingOccurrences(of: "²", with: "2"), c, 0.12, "TESTI")
        d.testo(s.soffitto.descrizione.replacingOccurrences(of: "≈", with: "~"), c + CGPoint(x: 0, y: 0.22), 0.12, "ALTEZZE")
    }

    /// Scrive DXF e JSON nella cartella temporanea e restituisce i file da condividere.
    static func file(_ r: Rilievo) -> [URL] {
        let nome = String(r.nome.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fDXF = dir.appendingPathComponent(nome + ".dxf")
        let fJSON = dir.appendingPathComponent(nome + ".rilievo.json")
        try? dxf(r).data(using: .windowsCP1252, allowLossyConversion: true)?.write(to: fDXF)
        try? Archivio.encoder.encode(r).write(to: fJSON)
        var out = [fDXF, fJSON]
        let cartella = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Nuvole")
        for (k, n) in (r.nuvole ?? []).enumerated() {
            let src = cartella.appendingPathComponent(n)
            let dst = dir.appendingPathComponent(nome + "_nuvola\((r.nuvole?.count ?? 0) > 1 ? "_\(k + 1)" : "").ply")
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { out.append(dst) }
        }
        return out
    }
}
