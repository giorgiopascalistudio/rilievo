import CoreGraphics
import Foundation

/// Modalità di prova per il simulatore: argomento di avvio "-prova nuovo|demo|scheda".
enum Prova {
    static var modo: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-prova"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var selezionaPrima: Bool { modo == "scheda" }

    static func rilievo() -> Rilievo? {
        guard let m = modo, m != "elenco" else { return nil }
        var r = Rilievo(nome: "Prova " + m)
        guard m != "nuovo" else { return r }
        var s = Stanza.nuova(nome: "Soggiorno", punti: [CGPoint(x: 0, y: 0), CGPoint(x: 5.2, y: 0), CGPoint(x: 5.2, y: 3.1),
                                                     CGPoint(x: 3.0, y: 3.1), CGPoint(x: 3.0, y: 4.6), CGPoint(x: 0, y: 4.6)])
        s.lati[0].lunghezza.misurato = 5.21
        s.lati[1].lunghezza.misurato = 3.12
        s.aperture.append(Apertura(tipo: .finestra, lato: 0, distanza: Quota(1.4), larghezza: Quota(1.2, misurato: 1.2),
                                   altezza: Quota(1.4), davanzale: Quota(0.9, misurato: 0.92)))
        s.aperture.append(Apertura(tipo: .porta, lato: 3, distanza: Quota(0.2), larghezza: Quota(0.8), altezza: Quota(2.1), davanzale: Quota(0)))
        s.ostacoli.append(Ostacolo(centro: CGPoint(x: 1.5, y: 2.2), w: 2.0, h: 0.9, angolo: 0, nome: "divano"))
        s.soffitto.tipo = .botte
        Risolutore.risolvi(&s)
        var c = Stanza.nuova(nome: "Cucina", punti: [CGPoint(x: 5.2, y: 0), CGPoint(x: 8.4, y: 0), CGPoint(x: 8.4, y: 3.1), CGPoint(x: 5.2, y: 3.1)])
        c.lati[0].spessore = Quota(0.3)
        r.stanze = [s, c]
        return r
    }
}
