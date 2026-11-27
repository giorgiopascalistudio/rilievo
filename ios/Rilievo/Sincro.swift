import Foundation

extension Notification.Name {
    /// Un rilievo è stato aggiornato dall'altro dispositivo (object: Rilievo).
    static let rilievoRemoto = Notification.Name("rilievoRemoto")
}

/// Sincronizzazione iPhone ⇄ iPad attraverso una cartella di iCloud Drive scelta dall'utente.
/// Non serve l'entitlement iCloud (che con l'Apple ID gratuito non si può avere): l'app scrive
/// i rilievi come file JSON nella cartella, iCloud Drive li porta sull'altro dispositivo.
/// Vince la versione modificata più di recente; le eliminazioni lasciano un file ".eliminato".
final class Sincro: ObservableObject {
    static let condivisa = Sincro()

    @Published private(set) var cartella: URL?
    @Published private(set) var ultima: Date?
    @Published private(set) var inCorso = false
    @Published var errore: String?

    private let chiave = "sincro.segnalibro"
    private let coda = DispatchQueue(label: "sincro", qos: .utility)
    private var eliminati: Set<UUID> = []

    var attiva: Bool { cartella != nil }
    var nomeCartella: String { cartella?.lastPathComponent ?? "" }

    private init() {
        if let d = UserDefaults.standard.data(forKey: chiave) {
            var vecchio = false
            if let u = try? URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &vecchio) {
                cartella = u
                if vecchio { salvaSegnalibro(u) }
            }
        }
        let el = UserDefaults.standard.stringArray(forKey: "sincro.eliminati") ?? []
        eliminati = Set(el.compactMap(UUID.init(uuidString:)))
    }

    func imposta(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        salvaSegnalibro(url)
        cartella = url
        errore = nil
    }

    func scollega() {
        UserDefaults.standard.removeObject(forKey: chiave)
        cartella = nil
    }

    private func salvaSegnalibro(_ u: URL) {
        if let d = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(d, forKey: chiave)
        }
    }

    func segnaEliminato(_ id: UUID) {
        eliminati.insert(id)
        UserDefaults.standard.set(eliminati.map(\.uuidString), forKey: "sincro.eliminati")
        sincronizza(nil)
    }

    private struct Remoto { var rilievi: [UUID: Rilievo] = [:]; var eliminati: Set<UUID> = [] }

    /// Legge la cartella in background, unisce sul main thread, scrive in background.
    func sincronizza(_ archivio: Archivio?) {
        guard let dir = cartella, !inCorso else { return }
        inCorso = true
        let eliminatiLocali = eliminati
        coda.async {
            let ok = dir.startAccessingSecurityScopedResource()
            let remoto = self.leggi(dir, eliminatiLocali: eliminatiLocali)
            if ok { dir.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                var daScrivere: [Rilievo] = []
                if let archivio {
                    for (id, r) in remoto.rilievi where !remoto.eliminati.contains(id) && !eliminatiLocali.contains(id) {
                        if let l = archivio.rilievo(id) {
                            if r.modificato.timeIntervalSince(l.modificato) > 0.5 {
                                archivio.salva(r)
                                NotificationCenter.default.post(name: .rilievoRemoto, object: r)
                            }
                        } else {
                            archivio.salva(r)
                        }
                    }
                    for id in remoto.eliminati where archivio.rilievo(id) != nil {
                        try? FileManager.default.removeItem(at: archivio.url(id))
                        archivio.rilievi.removeAll { $0.id == id }
                    }
                    for l in archivio.rilievi where !remoto.eliminati.contains(l.id) {
                        if let r = remoto.rilievi[l.id], r.modificato.timeIntervalSince(l.modificato) >= -0.5 { continue }
                        daScrivere.append(l)
                    }
                }
                self.coda.async {
                    let ok = dir.startAccessingSecurityScopedResource()
                    let err = self.scrivi(daScrivere, eliminati: eliminatiLocali.subtracting(remoto.eliminati), in: dir)
                    if ok { dir.stopAccessingSecurityScopedResource() }
                    DispatchQueue.main.async {
                        self.inCorso = false
                        self.errore = err
                        if err == nil { self.ultima = Date() }
                    }
                }
            }
        }
    }

    private func leggi(_ dir: URL, eliminatiLocali: Set<UUID>) -> Remoto {
        var out = Remoto()
        let fm = FileManager.default
        let coord = NSFileCoordinator()
        var e: NSError?
        var files: [URL] = []
        coord.coordinate(readingItemAt: dir, options: [], error: &e) { u in
            files = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [])) ?? []
        }
        for f in files {
            let nome = f.lastPathComponent
            if nome.hasPrefix("."), nome.hasSuffix(".icloud") {
                // file non ancora scaricato da iCloud: lo chiedo, arriverà al prossimo giro
                let vero = String(nome.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(vero))
                if vero.hasSuffix(".eliminato"), let id = UUID(uuidString: String(vero.dropLast(".eliminato".count))) {
                    out.eliminati.insert(id)
                }
                continue
            }
            if f.pathExtension == "eliminato", let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) {
                out.eliminati.insert(id)
                continue
            }
            guard f.pathExtension == "json" else { continue }
            coord.coordinate(readingItemAt: f, options: [], error: &e) { u in
                if let d = try? Data(contentsOf: u), let r = try? Archivio.decoder.decode(Rilievo.self, from: d) {
                    out.rilievi[r.id] = r
                }
            }
        }
        return out
    }

    private func scrivi(_ rilievi: [Rilievo], eliminati: Set<UUID>, in dir: URL) -> String? {
        let coord = NSFileCoordinator()
        var errore: String?
        for r in rilievi {
            guard let d = try? Archivio.encoder.encode(r) else { continue }
            let f = dir.appendingPathComponent(r.id.uuidString + ".json")
            var e: NSError?
            coord.coordinate(writingItemAt: f, options: .forReplacing, error: &e) { u in
                do { try d.write(to: u, options: .atomic) } catch { errore = error.localizedDescription }
            }
            if let e { errore = e.localizedDescription }
        }
        for id in eliminati {
            let f = dir.appendingPathComponent(id.uuidString + ".json")
            var e: NSError?
            coord.coordinate(writingItemAt: f, options: .forDeleting, error: &e) { u in try? FileManager.default.removeItem(at: u) }
            let t = dir.appendingPathComponent(id.uuidString + ".eliminato")
            coord.coordinate(writingItemAt: t, options: .forReplacing, error: &e) { u in try? Data("x".utf8).write(to: u) }
        }
        return errore
    }
}
