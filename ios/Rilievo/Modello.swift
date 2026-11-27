import CoreGraphics
import Foundation

/// Una misura: la stima (LiDAR o disegno) e, se presente, quella presa col distanziometro.
struct Quota: Codable, Equatable {
    var stimato: Double
    var misurato: Double?
    init(_ stimato: Double, misurato: Double? = nil) {
        self.stimato = stimato
        self.misurato = misurato
    }
    var valore: Double { misurato ?? stimato }
    var quotato: Bool { misurato != nil }
}

enum TipoApertura: String, Codable, CaseIterable, Identifiable {
    case porta, finestra, portafinestra, varco
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .porta: return "Porta"
        case .finestra: return "Finestra"
        case .portafinestra: return "Portafinestra"
        case .varco: return "Varco"
        }
    }
    var sigla: String {
        switch self {
        case .porta: return "P"
        case .finestra: return "F"
        case .portafinestra: return "PF"
        case .varco: return "V"
        }
    }
    var predefinita: (w: Double, h: Double, dav: Double) {
        switch self {
        case .porta: return (0.80, 2.10, 0)
        case .finestra: return (1.20, 1.40, 0.90)
        case .portafinestra: return (1.20, 2.40, 0)
        case .varco: return (0.90, 2.10, 0)
        }
    }
    var haAnta: Bool { self == .porta || self == .portafinestra }
}

struct Apertura: Codable, Identifiable, Equatable {
    var id = UUID()
    var tipo: TipoApertura
    var lato: Int
    /// dall'inizio del lato al bordo del vano
    var distanza: Quota
    var larghezza: Quota
    /// altezza del vano
    var altezza: Quota
    /// davanzale o soglia, da pavimento
    var davanzale: Quota
    /// 1 = cerniera sul vertice iniziale del lato, -1 = sul finale
    var verso: Int = 1
    var apreDentro: Bool = true

    var completa: Bool {
        distanza.quotato && larghezza.quotato && altezza.quotato && (tipo != .finestra || davanzale.quotato)
    }
    var sintesi: String {
        var s = "\(Fmt.cmIntero(larghezza.valore))×\(Fmt.cmIntero(altezza.valore))"
        if tipo == .finestra || davanzale.valore > 0.005 { s += " d\(Fmt.cmIntero(davanzale.valore))" }
        return s
    }
}

enum TipoSoffitto: String, Codable, CaseIterable, Identifiable {
    case piano, inclinato, botte, crociera, padiglione, schifo, cupola, altro
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .piano: return "Solaio piano"
        case .inclinato: return "Solaio inclinato"
        case .botte: return "Volta a botte"
        case .crociera: return "Volta a crociera"
        case .padiglione: return "Volta a padiglione"
        case .schifo: return "Volta a schifo"
        case .cupola: return "Cupola / trullo"
        case .altro: return "Altra volta"
        }
    }
    var volta: Bool { self != .piano && self != .inclinato }
    var haAsse: Bool { self == .botte || self == .schifo || self == .inclinato }
}

struct Soffitto: Codable, Equatable {
    var tipo: TipoSoffitto = .piano
    /// piano: altezza · inclinato: minima · volte: imposta
    var altezza = Quota(2.70)
    /// inclinato: massima · volte: chiave
    var altezzaMax = Quota(3.30)
    /// lato a cui è parallelo l'asse (botte, schifo) o il lato basso (inclinato)
    var latoAsse: Int = 0

    var descrizione: String {
        let h = (altezza.quotato ? "" : "≈") + Fmt.m(altezza.valore)
        let H = (altezzaMax.quotato ? "" : "≈") + Fmt.m(altezzaMax.valore)
        switch tipo {
        case .piano: return "h " + h
        case .inclinato: return "h " + h + " – " + H
        default: return "\(tipo.nome) · imp. \(h) · chiave \(H)"
        }
    }
}

struct Lato: Codable, Equatable {
    var lunghezza: Quota
    var spessore: Quota
}

struct Diagonale: Codable, Identifiable, Equatable {
    var id = UUID()
    var a: Int
    var b: Int
    var misurato: Double
}

/// Arredo riconosciuto dal LiDAR: non si esporta, serve solo a scegliere diagonali misurabili.
struct Ostacolo: Codable, Equatable {
    var centro: CGPoint
    var w: Double
    var h: Double
    var angolo: Double
    var nome: String

    var angoli: [CGPoint] {
        let u = CGPoint(x: cos(angolo), y: sin(angolo))
        let v = CGPoint(x: -u.y, y: u.x)
        let a = u * CGFloat(w / 2), b = v * CGFloat(h / 2)
        return [centro - a - b, centro + a - b, centro + a + b, centro - a + b]
    }
}

struct GeoApertura {
    let p1: CGPoint
    let p2: CGPoint
    let u: CGPoint
    let nOut: CGPoint
    let spessore: CGFloat
}

struct Stanza: Codable, Identifiable, Equatable {
    var id = UUID()
    var nome: String
    /// vertici in metri, sul filo interno dei muri
    var punti: [CGPoint]
    /// lato i = da punti[i] a punti[i+1]
    var lati: [Lato]
    var diagonali: [Diagonale] = []
    var aperture: [Apertura] = []
    var soffitto = Soffitto()
    var ostacoli: [Ostacolo] = []
    var origine = "disegno"
    /// fetta orizzontale della nuvola di punti (metri), mostrata sotto la pianta
    var traccia: [CGPoint]?
    /// nil/false = in squadra: angoli a 90° finché le diagonali misurate non dicono altro
    var angoliLiberi: Bool?
    var inSquadra: Bool { !(angoliLiberi ?? false) }

    static func nuova(nome: String, punti: [CGPoint], spessore: Double = 0.25) -> Stanza {
        let n = punti.count
        let lati = (0..<n).map { i in
            Lato(lunghezza: Quota(Double(punti[i].dist(punti[(i + 1) % n]))), spessore: Quota(spessore))
        }
        return Stanza(nome: nome, punti: punti, lati: lati)
    }

    var n: Int { punti.count }
    var area: Double { Double(abs(Geo.area(punti))) }
    var centro: CGPoint { Geo.centroide(punti) }

    func lunghezzaGeom(_ i: Int) -> Double { Double(punti[i].dist(punti[(i + 1) % n])) }
    func distanza(_ a: Int, _ b: Int) -> Double { Double(punti[a].dist(punti[b])) }

    func lettera(_ i: Int) -> String {
        i < 26 ? String(Character(UnicodeScalar(UInt8(65 + i)))) : "P\(i + 1)"
    }
    func nomeLato(_ i: Int) -> String { lettera(i) + "–" + lettera((i + 1) % n) }

    mutating func aggiornaStime() {
        for i in lati.indices where i < n { lati[i].lunghezza.stimato = lunghezzaGeom(i) }
    }

    func geometriaApertura(_ a: Apertura) -> GeoApertura? {
        guard a.lato >= 0, a.lato < n else { return nil }
        let A = punti[a.lato], B = punti[(a.lato + 1) % n]
        let u = (B - A).versore
        let p1 = A + u * CGFloat(a.distanza.valore)
        return GeoApertura(p1: p1, p2: p1 + u * CGFloat(a.larghezza.valore), u: u,
                           nOut: Geo.normaleEsterna(punti, a.lato), spessore: CGFloat(lati[a.lato].spessore.valore))
    }

    mutating func trasla(_ d: CGPoint) {
        punti = punti.map { $0 + d }
        for k in ostacoli.indices { ostacoli[k].centro = ostacoli[k].centro + d }
        traccia = traccia?.map { $0 + d }
    }

    mutating func dividiLato(_ i: Int) {
        let j = (i + 1) % n
        let L = lunghezzaGeom(i)
        let mid = CGPoint.medio(punti[i], punti[j])
        punti.insert(mid, at: i + 1)
        var nuovo = lati[i]
        nuovo.lunghezza = Quota(L / 2)
        lati[i].lunghezza = Quota(L / 2)
        lati.insert(nuovo, at: i + 1)
        for k in diagonali.indices {
            if diagonali[k].a > i { diagonali[k].a += 1 }
            if diagonali[k].b > i { diagonali[k].b += 1 }
        }
        for k in aperture.indices {
            if aperture[k].lato > i {
                aperture[k].lato += 1
            } else if aperture[k].lato == i && aperture[k].distanza.valore >= L / 2 {
                aperture[k].lato = i + 1
                aperture[k].distanza.stimato -= L / 2
                if let m = aperture[k].distanza.misurato { aperture[k].distanza.misurato = m - L / 2 }
            }
        }
        if soffitto.latoAsse > i { soffitto.latoAsse += 1 }
    }

    mutating func eliminaVertice(_ k: Int) {
        let n = self.n
        guard n > 3 else { return }
        let prev = (k - 1 + n) % n
        let Lprev = lunghezzaGeom(prev)
        func mappa(_ e: Int) -> Int { e < k ? e : e - 1 }
        for x in aperture.indices {
            if aperture[x].lato == k {
                aperture[x].lato = prev
                aperture[x].distanza.stimato += Lprev
                if let m = aperture[x].distanza.misurato { aperture[x].distanza.misurato = m + Lprev }
            }
            aperture[x].lato = mappa(aperture[x].lato)
        }
        diagonali.removeAll { $0.a == k || $0.b == k }
        for x in diagonali.indices {
            if diagonali[x].a > k { diagonali[x].a -= 1 }
            if diagonali[x].b > k { diagonali[x].b -= 1 }
        }
        lati[prev].lunghezza.misurato = nil
        punti.remove(at: k)
        lati.remove(at: k)
        let m = n - 1
        diagonali.removeAll { d in d.a == d.b || (d.a + 1) % m == d.b || (d.b + 1) % m == d.a }
        soffitto.latoAsse = min(mappa(soffitto.latoAsse == k ? prev : soffitto.latoAsse), m - 1)
        aggiornaStime()
    }
}

struct Rilievo: Codable, Identifiable, Equatable {
    var id = UUID()
    var nome: String
    var data = Date()
    var modificato = Date()
    var stanze: [Stanza] = []
    var note = ""
    /// nuvole di punti salvate (nomi file in Documenti/Nuvole)
    var nuvole: [String]?

    var superficie: Double { stanze.reduce(0) { $0 + $1.area } }
    var quoteFatte: (fatte: Int, totali: Int) {
        var f = 0, t = 0
        for s in stanze {
            t += s.n + max(0, s.n - 3)
            f += s.lati.filter { $0.lunghezza.quotato }.count + min(s.diagonali.count, max(0, s.n - 3))
        }
        return (f, t)
    }
}

/// Elenco dei rilievi salvati in Documenti/Rilievi.
final class Archivio: ObservableObject {
    @Published var rilievi: [Rilievo] = []
    let cartella: URL

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        cartella = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rilievi", isDirectory: true)
        try? FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
        carica()
    }

    func carica() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cartella, includingPropertiesForKeys: nil)) ?? []
        rilievi = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Rilievo.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modificato > $1.modificato }
    }

    func url(_ id: UUID) -> URL { cartella.appendingPathComponent(id.uuidString + ".json") }
    func rilievo(_ id: UUID) -> Rilievo? { rilievi.first { $0.id == id } }

    func salva(_ r: Rilievo) {
        if let d = try? Self.encoder.encode(r) { try? d.write(to: url(r.id), options: .atomic) }
        if let i = rilievi.firstIndex(where: { $0.id == r.id }) {
            rilievi[i] = r
        } else {
            rilievi.insert(r, at: 0)
        }
    }

    func elimina(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        rilievi.removeAll { $0.id == id }
        Sincro.condivisa.segnaEliminato(id)
    }
}
