import SwiftUI
import UIKit

struct VistaPianta: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeUIView(context: Context) -> TelaPianta {
        let v = TelaPianta()
        v.model = model
        return v
    }
    func updateUIView(_ v: TelaPianta, context: Context) { v.aggiorna() }
}

/// Tela della pianta: la Pencil disegna, il dito sposta/seleziona, due dita zoomano.
/// Le modifiche di geometria (risolutore, annulla, sincronizzazione) sono animate.
final class TelaPianta: UIView, UIGestureRecognizerDelegate {
    weak var model: EditorModel?

    private var scala: CGFloat = 60
    private var offset = CGPoint(x: 60, y: 160)
    private var tratto: [CGPoint] = []
    private var disegna = false
    private var mosso = false
    private var inizio = CGPoint.zero
    private var pencilVisto = false
    private var ultimoInquadra = -1
    private var primoLayout = true

    private enum Azione { case nessuna, pan(CGPoint), vertice(UUID, Int), stanza(UUID, CGPoint) }
    private var azione: Azione = .nessuna

    // animazione
    private var link: CADisplayLink?
    private var mostrati: [UUID: [CGPoint]] = [:]
    private var tempo: CFTimeInterval = 0
    private var schizzo: (id: UUID, tratto: [CGPoint], t0: CFTimeInterval)?
    private var ultimoSchizzo: UUID?
    private var vista: (s0: CGFloat, o0: CGPoint, s1: CGFloat, o1: CGPoint, t0: CFTimeInterval)?
    private var comparsa: [UUID: CFTimeInterval] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tema.fondo
        isMultipleTouchEnabled = true
        contentMode = .redraw
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pizzica(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scorri(_:)))
        pan.minimumNumberOfTouches = 2
        pinch.delegate = self
        pan.delegate = self
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
        link = CADisplayLink(target: self, selector: #selector(passo(_:)))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func removeFromSuperview() {
        link?.invalidate()
        super.removeFromSuperview()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

    private func w2s(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scala + offset.x, y: p.y * scala + offset.y) }
    private func s2w(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scala, y: (p.y - offset.y) / scala) }

    // MARK: aggiornamenti dal modello

    func aggiorna() {
        guard let m = model else { return }
        if m.inquadra != ultimoInquadra {
            ultimoInquadra = m.inquadra
            if !primoLayout { inquadra(animato: true) }
        }
        if let n = m.nataDaSchizzo, n.id != ultimoSchizzo {
            ultimoSchizzo = n.id
            schizzo = (n.id, n.tratto, CACurrentMediaTime())
        }
        for s in m.rilievo.stanze where mostrati[s.id] == nil {
            mostrati[s.id] = s.punti
            if schizzo?.id != s.id && !primoLayout { comparsa[s.id] = CACurrentMediaTime() }
        }
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if primoLayout && bounds.width > 10 {
            primoLayout = false
            inquadra(animato: false)
        }
    }

    private func inquadra(animato: Bool) {
        guard let m = model else { return }
        let pts = m.rilievo.stanze.flatMap(\.punti)
        guard !pts.isEmpty, bounds.width > 10 else { return }
        let box = Geo.riquadro(pts)
        let margine: CGFloat = 70
        let s1 = max(8, min(400, min((bounds.width - 2 * margine) / max(box.width, 1),
                                     (bounds.height - 2 * margine - 160) / max(box.height, 1))))
        let o1 = CGPoint(x: bounds.midX - box.midX * s1, y: bounds.midY - 50 - box.midY * s1)
        if animato {
            vista = (scala, offset, s1, o1, CACurrentMediaTime())
        } else {
            scala = s1
            offset = o1
        }
        setNeedsDisplay()
    }

    @objc private func passo(_ l: CADisplayLink) {
        guard let m = model else { return }
        tempo = l.timestamp
        var ridisegna = false
        if let v = vista {
            let t = min(1, (tempo - v.t0) / 0.45)
            let e = CGFloat(1 - pow(1 - t, 3))
            scala = v.s0 + (v.s1 - v.s0) * e
            offset = .lerp(v.o0, v.o1, e)
            if t >= 1 { vista = nil }
            ridisegna = true
        }
        for s in m.rilievo.stanze {
            guard var p = mostrati[s.id], p.count == s.punti.count else {
                mostrati[s.id] = s.punti
                ridisegna = true
                continue
            }
            var cambia = false
            for k in p.indices where p[k] != s.punti[k] {
                if m.trascinamento || p[k].dist(s.punti[k]) < 0.0005 {
                    p[k] = s.punti[k]
                } else {
                    p[k] = .lerp(p[k], s.punti[k], 0.22)
                }
                cambia = true
            }
            if cambia { mostrati[s.id] = p; ridisegna = true }
        }
        if schizzo != nil || !comparsa.isEmpty { ridisegna = true }
        if m.mostraDiagonali, let id = m.selezione.stanzaID, let s = m.stanza(id), s.n >= 4,
           s.diagonali.count < s.n - 2 { ridisegna = true }
        if ridisegna { setNeedsDisplay() }
    }

    /// La stanza come va disegnata in questo istante (vertici animati).
    private func vistaStanza(_ s: Stanza) -> Stanza {
        guard let p = mostrati[s.id], p.count == s.n else { return s }
        var c = s
        c.punti = p
        return c
    }

    // MARK: gesti

    @objc private func pizzica(_ g: UIPinchGestureRecognizer) {
        vista = nil
        let loc = g.location(in: self)
        let w = s2w(loc)
        scala = max(8, min(800, scala * g.scale))
        g.scale = 1
        offset = CGPoint(x: loc.x - w.x * scala, y: loc.y - w.y * scala)
        setNeedsDisplay()
    }

    @objc private func scorri(_ g: UIPanGestureRecognizer) {
        vista = nil
        offset = offset + g.translation(in: self)
        g.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let m = model, (event?.allTouches?.count ?? 1) == 1 else { return }
        let p = t.location(in: self)
        inizio = p
        mosso = false
        azione = .nessuna
        vista = nil
        if t.type == .pencil { pencilVisto = true }
        let w = s2w(p)
        if m.strumento.tipoApertura == nil, let sid = m.selezione.stanzaID, let s = m.stanza(sid),
           let k = s.punti.indices.min(by: { s.punti[$0].dist(w) < s.punti[$1].dist(w) }),
           s.punti[k].dist(w) * scala < 26 {
            m.registra()
            azione = .vertice(sid, k)
            return
        }
        let strumentoDisegno = m.strumento == .seleziona || m.strumento == .disegna
        disegna = t.type == .pencil ? strumentoDisegno : (m.strumento == .disegna && !pencilVisto)
        if disegna {
            tratto = [w]
            return
        }
        if case .stanza(let sid) = m.selezione, let s = m.stanza(sid), Geo.dentro(w, s.punti), m.strumento == .seleziona {
            m.registra()
            azione = .stanza(sid, w)
            return
        }
        azione = .pan(offset)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let m = model else { return }
        let p = t.location(in: self)
        if p.dist(inizio) > 6 { mosso = true }
        if disegna {
            for c in event?.coalescedTouches(for: t) ?? [t] { tratto.append(s2w(c.location(in: self))) }
            setNeedsDisplay()
            return
        }
        switch azione {
        case .pan(let o0):
            offset = o0 + (p - inizio)
            setNeedsDisplay()
        case .vertice(let sid, let k):
            if mosso {
                m.trascinamento = true
                m.spostaVertice(sid, k, a: s2w(p), aggancio: 14 / scala)
            }
        case .stanza(let sid, let w0):
            if mosso {
                m.trascinamento = true
                let w = s2w(p)
                m.traslaStanza(sid, di: w - w0)
                azione = .stanza(sid, w)
            }
        case .nessuna:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let m = model else { return }
        let p = t.location(in: self)
        defer {
            azione = .nessuna
            disegna = false
            tratto = []
            m.trascinamento = false
            setNeedsDisplay()
        }
        if disegna {
            if mosso && tratto.count > 4 {
                m.aggiungiTratto(tratto, eps: 12 / scala, chiusura: 44 / scala)
            } else {
                m.tocca(s2w(p), tol: 18 / scala)
            }
            return
        }
        switch azione {
        case .vertice(let sid, _):
            if mosso { m.fineTrascinamento(sid) } else { m.annullaRegistrazione(); m.tocca(s2w(p), tol: 18 / scala) }
        case .stanza:
            if mosso { m.salva() } else { m.annullaRegistrazione(); m.tocca(s2w(p), tol: 18 / scala) }
        default:
            if !mosso { m.tocca(s2w(p), tol: 18 / scala) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let m = model {
            switch azione {
            case .vertice(let sid, _) where mosso: m.fineTrascinamento(sid)
            case .stanza where mosso: m.salva()
            case .vertice, .stanza: m.annullaRegistrazione()
            default: break
            }
            m.trascinamento = false
        }
        azione = .nessuna
        disegna = false
        tratto = []
        setNeedsDisplay()
    }

    // MARK: disegno

    override func draw(_ rect: CGRect) {
        guard let m = model, let ctx = UIGraphicsGetCurrentContext() else { return }
        griglia(ctx)
        let ora = CACurrentMediaTime()
        for s0 in m.rilievo.stanze where s0.n >= 3 {
            let s = vistaStanza(s0)
            var alfa: CGFloat = 1
            if let sk = schizzo, sk.id == s.id {
                let t = min(1, (ora - sk.t0) / 0.55)
                alfa = CGFloat(t)
                disegnaTratto(sk.tratto, colore: Tema.accento.withAlphaComponent(CGFloat(1 - t)), larghezza: 3)
                if t >= 1 { schizzo = nil }
            } else if let c0 = comparsa[s.id] {
                let t = min(1, (ora - c0) / 0.5)
                alfa = CGFloat(t)
                if t >= 1 { comparsa[s.id] = nil }
            }
            ctx.saveGState()
            ctx.setAlpha(alfa)
            disegnaStanza(s, m, ctx)
            ctx.restoreGState()
        }
        if tratto.count > 1 {
            disegnaTratto(tratto, colore: Tema.accento, larghezza: 2.5)
        }
        righello(ctx)
    }

    private func disegnaTratto(_ t: [CGPoint], colore: UIColor, larghezza: CGFloat) {
        guard t.count > 1 else { return }
        let path = UIBezierPath()
        path.move(to: w2s(t[0]))
        for q in t.dropFirst() { path.addLine(to: w2s(q)) }
        path.lineWidth = larghezza
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        colore.setStroke()
        path.stroke()
    }

    private func griglia(_ ctx: CGContext) {
        let passi: [(CGFloat, CGFloat)] = scala >= 25 ? [(1, 0.10), (5, 0.20)] : [(5, 0.12), (25, 0.22)]
        let w0 = s2w(.zero), w1 = s2w(CGPoint(x: bounds.width, y: bounds.height))
        for (passo, a) in passi {
            let path = UIBezierPath()
            var x = (w0.x / passo).rounded(.down) * passo
            while x <= w1.x {
                let sx = x * scala + offset.x
                path.move(to: CGPoint(x: sx, y: 0))
                path.addLine(to: CGPoint(x: sx, y: bounds.height))
                x += passo
            }
            var y = (w0.y / passo).rounded(.down) * passo
            while y <= w1.y {
                let sy = y * scala + offset.y
                path.move(to: CGPoint(x: 0, y: sy))
                path.addLine(to: CGPoint(x: bounds.width, y: sy))
                y += passo
            }
            Tema.griglia.withAlphaComponent(a).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func righello(_ ctx: CGContext) {
        let opzioni: [CGFloat] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50]
        let metri = opzioni.first { $0 * scala >= 60 } ?? 50
        let L = metri * scala
        let o = CGPoint(x: 18, y: safeAreaInsets.top + 18)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: o.x, y: o.y + 6))
        p.addLine(to: CGPoint(x: o.x, y: o.y + 12))
        p.addLine(to: CGPoint(x: o.x + L, y: o.y + 12))
        p.addLine(to: CGPoint(x: o.x + L, y: o.y + 6))
        Tema.testo.withAlphaComponent(0.7).setStroke()
        p.lineWidth = 1.5
        p.stroke()
        scrivi(metri >= 1 ? "\(Int(metri)) m" : "\(Int(metri * 100)) cm", CGPoint(x: o.x + L / 2, y: o.y), size: 10, color: Tema.testo2)
    }

    private func poligono(_ p: [CGPoint]) -> UIBezierPath {
        let b = UIBezierPath()
        guard let f = p.first else { return b }
        b.move(to: f)
        for q in p.dropFirst() { b.addLine(to: q) }
        b.close()
        return b
    }

    private func disegnaStanza(_ s: Stanza, _ m: EditorModel, _ ctx: CGContext) {
        let n = s.n
        let sel = m.selezione
        let selezionata = sel.stanzaID == s.id
        let P = s.punti.map(w2s)
        let E = Geo.contornoEsterno(s.punti, s.lati.map { CGFloat($0.spessore.valore) }).map(w2s)
        let C = w2s(s.centro)
        let stato = Risolutore.stato(s)

        // pavimento
        let pav = poligono(P)
        (selezionata ? Tema.accento.withAlphaComponent(0.10) : Tema.pavimento.withAlphaComponent(0.55)).setFill()
        pav.fill()

        // traccia della nuvola di punti
        if m.mostraNuvola, let tr = s.traccia, !tr.isEmpty {
            let r: CGFloat = max(0.6, min(1.6, scala / 70))
            Tema.accento.withAlphaComponent(0.55).setFill()
            let box = bounds.insetBy(dx: -10, dy: -10)
            for q in tr {
                let p = w2s(q)
                if box.contains(p) { UIRectFill(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            }
        }

        // arredi rilevati (solo riferimento)
        if m.mostraArredi {
            for o in s.ostacoli {
                let r = poligono(o.angoli.map(w2s))
                r.setLineDash([4, 3], count: 2, phase: 0)
                r.lineWidth = 1
                Tema.testo2.withAlphaComponent(0.45).setStroke()
                r.stroke()
                if scala > 45 { scrivi(o.nome, w2s(o.centro), size: 9, color: Tema.testo2.withAlphaComponent(0.7)) }
            }
        }

        // muri
        for i in 0..<n {
            let j = (i + 1) % n
            let q = poligono([P[i], P[j], E[j], E[i]])
            Tema.muro.setFill()
            q.fill()
        }
        if selezionata {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 12, color: Tema.accento.withAlphaComponent(0.8).cgColor)
            let bordo = poligono(P)
            bordo.lineWidth = 1.5
            Tema.accento.setStroke()
            bordo.stroke()
            ctx.restoreGState()
        }

        // aperture
        for a in s.aperture {
            guard let g = s.geometriaApertura(a) else { continue }
            let t = g.spessore
            let A1 = w2s(g.p1), A2 = w2s(g.p2), B1 = w2s(g.p1 + g.nOut * t), B2 = w2s(g.p2 + g.nOut * t)
            let vano = poligono([A1, A2, B2, B1])
            Tema.fondo.setFill()
            vano.fill()
            let segno = UIBezierPath()
            segno.lineWidth = 1.2
            segno.move(to: A1); segno.addLine(to: B1)
            segno.move(to: A2); segno.addLine(to: B2)
            if a.tipo == .finestra || a.tipo == .portafinestra {
                for f in [t / 3, 2 * t / 3] {
                    segno.move(to: w2s(g.p1 + g.nOut * f))
                    segno.addLine(to: w2s(g.p2 + g.nOut * f))
                }
            }
            Tema.muro.setStroke()
            segno.stroke()
            if a.tipo == .varco {
                let v = UIBezierPath()
                v.move(to: A1); v.addLine(to: A2)
                v.setLineDash([3, 3], count: 2, phase: 0)
                v.lineWidth = 1
                Tema.testo2.setStroke()
                v.stroke()
            }
            if a.tipo.haAnta {
                let w = CGFloat(a.larghezza.valore)
                let cerniera = a.verso == 1 ? g.p1 : g.p2
                let chiusa = a.verso == 1 ? g.p2 : g.p1
                let dir = a.apreDentro ? g.nOut * -1 : g.nOut
                let base = a.apreDentro ? cerniera : cerniera + g.nOut * t
                let chiusaB = a.apreDentro ? chiusa : chiusa + g.nOut * t
                let foglia = base + dir * w
                let H = w2s(base), F = w2s(foglia), K = w2s(chiusaB)
                let anta = UIBezierPath()
                anta.move(to: H); anta.addLine(to: F)
                anta.lineWidth = 2
                Tema.accento.withAlphaComponent(0.9).setStroke()
                anta.stroke()
                let a0 = atan2(K.y - H.y, K.x - H.x), a1 = atan2(F.y - H.y, F.x - H.x)
                var d = a1 - a0
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                let arco = UIBezierPath(arcCenter: H, radius: w * scala, startAngle: a0, endAngle: a0 + d, clockwise: d > 0)
                arco.lineWidth = 0.8
                arco.setLineDash([4, 3], count: 2, phase: 0)
                Tema.accento.withAlphaComponent(0.6).setStroke()
                arco.stroke()
            }
            if case .apertura(_, let aid) = sel, aid == a.id {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 10, color: Tema.accento.cgColor)
                vano.lineWidth = 2.5
                Tema.accento.setStroke()
                vano.stroke()
                ctx.restoreGState()
            }
            if scala > 38 {
                let mid = w2s(CGPoint.medio(g.p1, g.p2) - g.nOut * 0.32)
                scrivi("\(a.tipo.sigla) \(a.sintesi)", mid, size: 9.5,
                       color: a.completa ? Tema.misurato : Tema.stimato, angolo: Geo.angoloLeggibile(A1, A2), sfondo: true)
            }
        }

        // diagonali
        if m.mostraDiagonali {
            for d in s.diagonali where d.a < n && d.b < n {
                let path = UIBezierPath()
                path.move(to: P[d.a]); path.addLine(to: P[d.b])
                path.lineWidth = isDiag(sel, s.id, d.a, d.b) ? 3 : 1.4
                Tema.misurato.withAlphaComponent(0.85).setStroke()
                path.stroke()
                scrivi(Fmt.m(d.misurato), .medio(P[d.a], P[d.b]), size: 10, color: Tema.misurato, peso: .semibold,
                       angolo: Geo.angoloLeggibile(P[d.a], P[d.b]), sfondo: true)
            }
            let fase = CGFloat(tempo.truncatingRemainder(dividingBy: 1) * 20)
            let pulsa = CGFloat(0.55 + 0.45 * sin(tempo * 4))
            for g in Risolutore.diagonaliDaMisurare(s) {
                let path = UIBezierPath()
                path.move(to: P[g.a]); path.addLine(to: P[g.b])
                let col = g.controllo ? Tema.controllo : Tema.stimato
                path.lineWidth = isDiag(sel, s.id, g.a, g.b) ? 3 : 1.6
                path.setLineDash([7, 5], count: 2, phase: selezionata ? -fase : 0)
                col.withAlphaComponent(selezionata ? pulsa : 0.5).setStroke()
                path.stroke()
                if selezionata || scala > 50 {
                    scrivi(g.controllo ? "controllo" : "misura", .medio(P[g.a], P[g.b]), size: 9.5, color: col,
                           peso: .semibold, angolo: Geo.angoloLeggibile(P[g.a], P[g.b]), sfondo: true)
                }
            }
        }

        // quote dei lati
        for i in 0..<n {
            let j = (i + 1) % n
            let L = P[i].dist(P[j])
            let no = Geo.normaleEsterna(s.punti, i)
            if case .lato(let id, let k) = sel, id == s.id, k == i {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 10, color: Tema.accento.cgColor)
                let l = UIBezierPath()
                l.move(to: P[i]); l.addLine(to: P[j])
                l.lineWidth = 4
                l.lineCapStyle = .round
                Tema.accento.setStroke()
                l.stroke()
                ctx.restoreGState()
            }
            guard L > 38 else { continue }
            let q = s.lati[i].lunghezza
            let testo = q.quotato ? Fmt.m(q.misurato!) : "≈" + Fmt.m(s.lunghezzaGeom(i))
            let pos = CGPoint.medio(P[i], P[j]) - no * 15
            scrivi(testo, pos, size: q.quotato ? 12 : 11, color: q.quotato ? Tema.misurato : Tema.stimato,
                   peso: q.quotato ? .bold : .medium, angolo: Geo.angoloLeggibile(P[i], P[j]))
        }

        // vertici
        if selezionata || scala > 45 {
            for i in 0..<n {
                let dir = (C - P[i]).versore
                scrivi(s.lettera(i), P[i] + dir * 16, size: 10, color: Tema.testo2, peso: .bold)
                if selezionata {
                    let r: CGFloat = { if case .vertice(_, let k) = sel, k == i { return 8 }; return 5 }()
                    let c = UIBezierPath(ovalIn: CGRect(x: P[i].x - r, y: P[i].y - r, width: 2 * r, height: 2 * r))
                    Tema.fondo.setFill(); c.fill()
                    c.lineWidth = 2
                    Tema.accento.setStroke(); c.stroke()
                }
            }
        }
        // fuori squadra
        for f in stato.fuoriSquadra {
            let dir = (C - P[f.id]).versore
            scrivi(Fmt.gradi(f.gradi), P[f.id] + dir * 34, size: 10, color: Tema.stimato, peso: .semibold, sfondo: true)
        }

        // etichetta stanza
        if scala > 20 {
            scrivi(s.nome, C - CGPoint(x: 0, y: 16), size: 14, color: Tema.testo, peso: .semibold)
            scrivi(Fmt.area(s.area), C + CGPoint(x: 0, y: 2), size: 11, color: Tema.testo2)
            scrivi(s.soffitto.descrizione, C + CGPoint(x: 0, y: 18), size: 10,
                   color: s.soffitto.altezza.quotato ? Tema.misurato : Tema.stimato)
            if stato.bloccata {
                scrivi("● bloccata", C + CGPoint(x: 0, y: 33), size: 9.5, color: Tema.misurato, peso: .semibold)
            }
        }
    }

    private func isDiag(_ sel: Selezione, _ id: UUID, _ a: Int, _ b: Int) -> Bool {
        if case .diagonale(let s, let x, let y) = sel, s == id, (x == a && y == b) || (x == b && y == a) { return true }
        return false
    }

    private func scrivi(_ s: String, _ p: CGPoint, size: CGFloat, color: UIColor, peso: UIFont.Weight = .regular,
                        angolo: CGFloat = 0, sfondo: Bool = false) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: peso)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = str.size()
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angolo)
        let r = CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height)
        if sfondo {
            Tema.fondo.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: r.insetBy(dx: -4, dy: -1.5), cornerRadius: 4).fill()
        }
        str.draw(at: r.origin)
        ctx.restoreGState()
    }
}
