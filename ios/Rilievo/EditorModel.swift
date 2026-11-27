import SwiftUI
import RoomPlan

enum Strumento: String, CaseIterable, Identifiable {
    case seleziona, disegna, porta, finestra, portafinestra, varco
    var id: String { rawValue }
    var tipoApertura: TipoApertura? { TipoApertura(rawValue: rawValue) }
    var nome: String {
        switch self {
        case .seleziona: return "Sposta"
        case .disegna: return "Disegna"
        case .porta: return "Porta"
        case .finestra: return "Finestra"
        case .portafinestra: return "P.finestra"
        case .varco: return "Varco"
        }
    }
    var icona: String {
        switch self {
        case .seleziona: return "hand.point.up.left"
        case .disegna: return "pencil.tip"
        case .porta: return "door.left.hand.open"
        case .finestra: return "window.vertical.closed"
        case .portafinestra: return "door.french.open"
        case .varco: return "rectangle.portrait"
        }
    }
}

enum Selezione: Equatable {
    case nessuna
    case stanza(UUID)
    case lato(UUID, Int)
    case vertice(UUID, Int)
    case apertura(UUID, UUID)
    case diagonale(UUID, Int, Int)

    var stanzaID: UUID? {
        switch self {
        case .nessuna: return nil
        case .stanza(let i), .lato(let i, _), .vertice(let i, _), .apertura(let i, _), .diagonale(let i, _, _): return i
        }
    }
}

/// Stato dell'editor di un rilievo: tutte le modifiche passano da qui (annulla, salvataggio, risolutore).
final class EditorModel: ObservableObject {
    @Published var rilievo: Rilievo
    @Published var selezione: Selezione = .nessuna
    @Published var strumento: Strumento = .seleziona
    @Published var mostraArredi = true
    @Published var mostraDiagonali = true
    @Published var avviso: String?
    @Published var inquadra = 0
    /// ultima stanza nata da uno schizzo, per l'animazione schizzo → linee dritte
    @Published var nataDaSchizzo: (id: UUID, tratto: [CGPoint])?

    private var storia: [Rilievo] = []
    private let archivio: Archivio
    private var osservatore: NSObjectProtocol?
    var trascinamento = false

    var puoAnnullare: Bool { !storia.isEmpty }

    init(rilievo: Rilievo, archivio: Archivio) {
        self.rilievo = rilievo
        self.archivio = archivio
        osservatore = NotificationCenter.default.addObserver(forName: .rilievoRemoto, object: nil, queue: .main) { [weak self] n in
            guard let self, let r = n.object as? Rilievo, r.id == self.rilievo.id, !self.trascinamento,
                  r.modificato > self.rilievo.modificato else { return }
            self.rilievo = r
            self.validaSelezione()
            self.avviso = "Aggiornato dall'altro dispositivo"
        }
    }

    deinit { if let o = osservatore { NotificationCenter.default.removeObserver(o) } }

    // MARK: base

    func indice(_ id: UUID) -> Int? { rilievo.stanze.firstIndex { $0.id == id } }
    func stanza(_ id: UUID) -> Stanza? { indice(id).map { rilievo.stanze[$0] } }

    func registra() {
        storia.append(rilievo)
        if storia.count > 80 { storia.removeFirst() }
    }
    func annullaRegistrazione() { _ = storia.popLast() }

    func annulla() {
        guard let r = storia.popLast() else { return }
        withAnimation(.spring(response: 0.35)) { rilievo = r }
        validaSelezione()
        salva()
    }

    func salva() {
        rilievo.modificato = Date()
        archivio.salva(rilievo)
    }

    func validaSelezione() {
        switch selezione {
        case .nessuna: return
        case .stanza(let id): if stanza(id) == nil { selezione = .nessuna }
        case .lato(let id, let i), .vertice(let id, let i):
            if (stanza(id)?.n ?? 0) <= i { selezione = .nessuna }
        case .apertura(let id, let a):
            if stanza(id)?.aperture.contains(where: { $0.id == a }) != true { selezione = .nessuna }
        case .diagonale(let id, let a, let b):
            let n = stanza(id)?.n ?? 0
            if a >= n || b >= n { selezione = .nessuna }
        }
    }

    func modificaStanza(_ id: UUID, annullabile: Bool = true, risolvi: Bool = false, _ corpo: (inout Stanza) -> Void) {
        guard let i = indice(id) else { return }
        if annullabile { registra() }
        var s = rilievo.stanze[i]
        corpo(&s)
        if risolvi {
            let sc = Risolutore.risolvi(&s)
            if sc > 0.01 {
                avviso = "\(s.nome): le misure non tornano (scarto \(Fmt.cm(sc))). Ricontrolla l'ultima."
            }
        } else {
            s.aggiornaStime()
        }
        rilievo.stanze[i] = s
        salva()
    }

    func modificaApertura(_ sid: UUID, _ aid: UUID, _ corpo: (inout Apertura) -> Void) {
        modificaStanza(sid) { s in
            if let k = s.aperture.firstIndex(where: { $0.id == aid }) { corpo(&s.aperture[k]) }
        }
    }

    func rinomina(_ nome: String) {
        let t = nome.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        rilievo.nome = t
        salva()
    }

    // MARK: azioni

    func eliminaStanza(_ id: UUID) {
        registra()
        withAnimation(.easeInOut) { rilievo.stanze.removeAll { $0.id == id } }
        selezione = .nessuna
        salva()
    }

    func eliminaApertura(_ sid: UUID, _ aid: UUID) {
        modificaStanza(sid) { $0.aperture.removeAll { $0.id == aid } }
        selezione = .stanza(sid)
    }

    func dividiLato(_ id: UUID, _ i: Int) {
        modificaStanza(id) { $0.dividiLato(i) }
        selezione = .vertice(id, i + 1)
    }

    func eliminaVertice(_ id: UUID, _ k: Int) {
        guard let s = stanza(id), s.n > 3 else { avviso = "Una stanza ha almeno 3 vertici"; return }
        modificaStanza(id, risolvi: true) { $0.eliminaVertice(k) }
        selezione = .stanza(id)
    }

    func setDiagonale(_ id: UUID, _ a: Int, _ b: Int, _ valore: Double?) {
        modificaStanza(id, risolvi: true) { s in
            if let k = s.diagonali.firstIndex(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }) {
                if let v = valore { s.diagonali[k].misurato = v } else { s.diagonali.remove(at: k) }
            } else if let v = valore {
                s.diagonali.append(Diagonale(a: a, b: b, misurato: v))
            }
        }
    }

    private var asse: Double? {
        guard let s = rilievo.stanze.first, s.n >= 2 else { return nil }
        let i = (0..<s.n).max { s.lunghezzaGeom($0) < s.lunghezzaGeom($1) } ?? 0
        let d = s.punti[(i + 1) % s.n] - s.punti[i]
        return Double(atan2(d.y, d.x))
    }

    /// Schizzo a mano libera → stanza a lati dritti.
    func aggiungiTratto(_ tratto: [CGPoint], eps: CGFloat, chiusura: CGFloat) {
        guard var poly = Geo.raddrizza(tratto, eps: eps, chiusura: chiusura, asse: asse) else {
            avviso = "Chiudi il perimetro tornando al punto di partenza"
            return
        }
        let esistenti = rilievo.stanze.flatMap(\.punti)
        for k in poly.indices {
            if let v = esistenti.min(by: { $0.dist(poly[k]) < $1.dist(poly[k]) }), v.dist(poly[k]) < chiusura * 0.6 {
                poly[k] = v
            }
        }
        guard abs(Geo.area(poly)) > 0.15 else { avviso = "Stanza troppo piccola"; return }
        registra()
        let s = Stanza.nuova(nome: "Stanza \(rilievo.stanze.count + 1)", punti: poly)
        rilievo.stanze.append(s)
        nataDaSchizzo = (s.id, tratto)
        selezione = .stanza(s.id)
        strumento = .seleziona
        salva()
    }

    func tocca(_ w: CGPoint, tol: CGFloat) {
        if let tipo = strumento.tipoApertura {
            aggiungiApertura(at: w, tipo: tipo, tol: tol)
        } else {
            seleziona(w, tol: tol)
        }
    }

    func seleziona(_ w: CGPoint, tol: CGFloat) {
        let corrente = selezione.stanzaID
        if let id = corrente, let s = stanza(id),
           let k = s.punti.indices.first(where: { s.punti[$0].dist(w) < tol * 1.3 }) {
            selezione = .vertice(id, k)
            return
        }
        for s in rilievo.stanze {
            for a in s.aperture {
                guard let g = s.geometriaApertura(a) else { continue }
                let off = g.nOut * (g.spessore / 2)
                if Geo.distSegmento(w, g.p1 + off, g.p2 + off).d < max(tol, g.spessore * 0.7) {
                    selezione = .apertura(s.id, a.id)
                    return
                }
            }
        }
        if let id = corrente, let s = stanza(id), mostraDiagonali {
            for d in s.diagonali where d.a < s.n && d.b < s.n && Geo.distSegmento(w, s.punti[d.a], s.punti[d.b]).d < tol {
                selezione = .diagonale(id, d.a, d.b)
                return
            }
            for g in Risolutore.diagonaliDaMisurare(s) where Geo.distSegmento(w, s.punti[g.a], s.punti[g.b]).d < tol {
                selezione = .diagonale(id, g.a, g.b)
                return
            }
        }
        var migliore: (UUID, Int, CGFloat)?
        for s in rilievo.stanze {
            let dentro = Geo.dentro(w, s.punti)
            for i in 0..<s.n {
                let r = Geo.distSegmento(w, s.punti[i], s.punti[(i + 1) % s.n])
                let lim = dentro ? tol : max(tol, CGFloat(s.lati[i].spessore.valore) + tol * 0.3)
                if r.d < lim, migliore == nil || r.d < migliore!.2 { migliore = (s.id, i, r.d) }
            }
        }
        if let m = migliore { selezione = .lato(m.0, m.1); return }
        if let s = rilievo.stanze.last(where: { Geo.dentro(w, $0.punti) }) {
            selezione = .stanza(s.id)
            return
        }
        selezione = .nessuna
    }

    func aggiungiApertura(at w: CGPoint, tipo: TipoApertura, tol: CGFloat) {
        var best: (Int, Int, CGFloat, CGFloat)?
        for (si, s) in rilievo.stanze.enumerated() {
            for i in 0..<s.n {
                let r = Geo.distSegmento(w, s.punti[i], s.punti[(i + 1) % s.n])
                let lim = tol + CGFloat(s.lati[i].spessore.valore)
                if r.d < lim, best == nil || r.d < best!.2 { best = (si, i, r.d, r.t) }
            }
        }
        guard let b = best else {
            avviso = "Tocca un muro per inserire: \(tipo.nome.lowercased())"
            return
        }
        inserisciApertura(rilievo.stanze[b.0].id, lato: b.1, t: Double(b.3), tipo: tipo)
    }

    func aggiungiAperturaSuLato(_ id: UUID, _ i: Int, _ tipo: TipoApertura) {
        inserisciApertura(id, lato: i, t: 0.5, tipo: tipo)
    }

    private func inserisciApertura(_ id: UUID, lato: Int, t: Double, tipo: TipoApertura) {
        guard let s = stanza(id) else { return }
        let L = s.lunghezzaGeom(lato)
        let def = tipo.predefinita
        let w = min(def.w, L)
        let dist = max(0, min(L - w, t * L - w / 2))
        let a = Apertura(tipo: tipo, lato: lato, distanza: Quota(dist), larghezza: Quota(w),
                         altezza: Quota(def.h), davanzale: Quota(def.dav))
        modificaStanza(id) { $0.aperture.append(a) }
        selezione = .apertura(id, a.id)
        strumento = .seleziona
    }

    // MARK: trascinamento

    func spostaVertice(_ id: UUID, _ k: Int, a p: CGPoint, aggancio: CGFloat) {
        guard let i = indice(id), k < rilievo.stanze[i].n else { return }
        var q = p
        for (j, s) in rilievo.stanze.enumerated() where j != i {
            for v in s.punti where v.dist(q) < aggancio { q = v }
        }
        rilievo.stanze[i].punti[k] = q
        rilievo.stanze[i].aggiornaStime()
    }

    func traslaStanza(_ id: UUID, di d: CGPoint) {
        guard let i = indice(id) else { return }
        rilievo.stanze[i].trasla(d)
    }

    func fineTrascinamento(_ id: UUID) {
        modificaStanza(id, annullabile: false, risolvi: true) { _ in }
    }

    // MARK: LiDAR

    func importaLidar(_ stanze: [CapturedRoom]) {
        var nuove: [Stanza] = []
        for (k, r) in stanze.enumerated() {
            if let s = Lidar.stanza(r, nome: "Stanza \(rilievo.stanze.count + k + 1)") { nuove.append(s) }
        }
        guard !nuove.isEmpty else {
            avviso = "Nessuna stanza ricostruita: servono almeno 3 pareti chiuse"
            return
        }
        registra()
        if !rilievo.stanze.isEmpty {
            let vecchio = Geo.riquadro(rilievo.stanze.flatMap(\.punti))
            let nuovo = Geo.riquadro(nuove.flatMap(\.punti))
            if vecchio.intersects(nuovo) {
                let d = CGPoint(x: vecchio.maxX + 1 - nuovo.minX, y: vecchio.minY - nuovo.minY)
                for k in nuove.indices { nuove[k].trasla(d) }
            }
        }
        rilievo.stanze += nuove
        selezione = .stanza(nuove[0].id)
        inquadra += 1
        salva()
        let scartate = stanze.count - nuove.count
        avviso = scartate > 0 ? "\(nuove.count) stanze importate, \(scartate) non ricostruibili"
                              : "\(nuove.count) stanze importate: ora quotale col distanziometro"
    }
}
