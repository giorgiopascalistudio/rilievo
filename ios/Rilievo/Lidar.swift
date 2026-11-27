import SwiftUI
import RoomPlan
import simd

/// Conversione di una stanza RoomPlan nella pianta parametrica dell'app.
/// Pareti, porte, finestre e aperture diventano elementi quotabili; gli arredi restano solo come
/// ingombri (per scegliere diagonali misurabili) e non vengono esportati.
enum Lidar {
    private struct Muro { var a: CGPoint; var b: CGPoint; var base: Float; var cima: Float }

    private static func muro(_ s: CapturedRoom.Surface) -> Muro {
        let t = s.transform
        let c = CGPoint(x: CGFloat(t.columns.3.x), y: CGFloat(t.columns.3.z))
        let d = CGPoint(x: CGFloat(t.columns.0.x), y: CGFloat(t.columns.0.z)).versore
        let h = CGFloat(s.dimensions.x) / 2
        return Muro(a: c - d * h, b: c + d * h,
                    base: t.columns.3.y - s.dimensions.y / 2, cima: t.columns.3.y + s.dimensions.y / 2)
    }

    private static func mediana(_ v: [Float]) -> Float {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    static func stanza(_ room: CapturedRoom, nome: String) -> Stanza? {
        let tutti = room.walls.map(muro)
        var muri = tutti.filter { $0.a.dist($0.b) > 0.15 }
        guard muri.count >= 3 else { return nil }

        // concatena le pareti cercando ogni volta l'estremo più vicino
        var ordine = [muri.removeFirst()]
        while !muri.isEmpty {
            let fine = ordine[ordine.count - 1].b
            var best = 0
            var bestD = CGFloat.greatestFiniteMagnitude
            var inverti = false
            for (k, w) in muri.enumerated() {
                let da = w.a.dist(fine), db = w.b.dist(fine)
                if da < bestD { bestD = da; best = k; inverti = false }
                if db < bestD { bestD = db; best = k; inverti = true }
            }
            if bestD > 1.5 { break }
            var w = muri.remove(at: best)
            if inverti { swap(&w.a, &w.b) }
            ordine.append(w)
        }
        guard ordine.count >= 3 else { return nil }

        let m = ordine.count
        var punti: [CGPoint] = []
        for k in 0..<m {
            let h = ordine[(k - 1 + m) % m], w = ordine[k]
            let dh = (h.b - h.a).versore, dw = (w.b - w.a).versore
            if let x = Geo.intersezione(h.a, dh, w.a, dw), x.dist(w.a) < 2 {
                punti.append(x)
            } else {
                punti.append(.medio(h.b, w.a))
            }
        }
        punti = Geo.pulisci(punti)
        guard punti.count >= 3, abs(Geo.area(punti)) > 0.5 else { return nil }

        var s = Stanza.nuova(nome: nome, punti: punti)
        s.origine = "lidar"
        let pavimento = mediana(tutti.map(\.base))
        let soffitto = mediana(tutti.map(\.cima)) - pavimento
        s.soffitto.altezza = Quota(Double(soffitto))
        s.soffitto.altezzaMax = Quota(Double(soffitto) + 0.5)

        for d in room.doors {
            if let a = apertura(d, tipo: .porta, in: s, pavimento: pavimento) { s.aperture.append(a) }
        }
        for f in room.windows {
            if let a = apertura(f, tipo: .finestra, in: s, pavimento: pavimento) { s.aperture.append(a) }
        }
        for o in room.openings {
            if let a = apertura(o, tipo: .varco, in: s, pavimento: pavimento) { s.aperture.append(a) }
        }
        for o in room.objects {
            let t = o.transform
            s.ostacoli.append(Ostacolo(centro: CGPoint(x: CGFloat(t.columns.3.x), y: CGFloat(t.columns.3.z)),
                                       w: Double(o.dimensions.x), h: Double(o.dimensions.z),
                                       angolo: atan2(Double(t.columns.0.z), Double(t.columns.0.x)),
                                       nome: nomeOggetto(o.category)))
        }
        return s
    }

    private static func apertura(_ x: CapturedRoom.Surface, tipo: TipoApertura, in s: Stanza, pavimento: Float) -> Apertura? {
        let t = x.transform
        let c = CGPoint(x: CGFloat(t.columns.3.x), y: CGFloat(t.columns.3.z))
        let w = Double(x.dimensions.x), h = Double(x.dimensions.y)
        let dav = Double(t.columns.3.y - x.dimensions.y / 2 - pavimento)
        var best: (lato: Int, d: CGFloat, t: CGFloat)?
        for i in 0..<s.n {
            let r = Geo.distSegmento(c, s.punti[i], s.punti[(i + 1) % s.n])
            if best == nil || r.d < best!.d { best = (i, r.d, r.t) }
        }
        guard let b = best, b.d < 0.6 else { return nil }
        let L = s.lunghezzaGeom(b.lato)
        let dist = max(0, min(L - w, Double(b.t) * L - w / 2))
        var tipo = tipo
        if tipo == .finestra && dav < 0.25 { tipo = .portafinestra }
        return Apertura(tipo: tipo, lato: b.lato, distanza: Quota(dist), larghezza: Quota(min(w, L)),
                        altezza: Quota(h), davanzale: Quota(max(0, dav)))
    }

    private static func nomeOggetto(_ c: CapturedRoom.Object.Category) -> String {
        let nomi = ["storage": "mobile", "refrigerator": "frigo", "stove": "cucina", "bed": "letto",
                    "sink": "lavello", "washerDryer": "lavatrice", "toilet": "wc", "bathtub": "vasca",
                    "oven": "forno", "dishwasher": "lavastoviglie", "table": "tavolo", "sofa": "divano",
                    "chair": "sedia", "fireplace": "camino", "television": "tv", "stairs": "scala"]
        let k = String(describing: c)
        return nomi[k] ?? k
    }
}

// MARK: - Schermata di scansione

final class StatoScansione: ObservableObject {
    enum Fase { case avvio, scansione, elaborazione, rivedi }
    @Published var fase: Fase = .avvio
    @Published var stanze: [CapturedRoom] = []
    @Published var errore: String?
    weak var vc: ScanVC?
}

final class ScanVC: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    let stato: StatoScansione
    private var vista: RoomCaptureView!

    init(stato: StatoScansione) {
        self.stato = stato
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("non usato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        vista = RoomCaptureView(frame: view.bounds)
        vista.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vista.delegate = self
        vista.captureSession.delegate = self
        view.addSubview(vista)
        stato.vc = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if stato.fase == .avvio { avvia() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        vista.captureSession.stop()
    }

    func avvia() {
        vista.captureSession.run(configuration: RoomCaptureSession.Configuration())
        stato.fase = .scansione
    }

    /// Ferma la stanza ma tiene viva la sessione AR: la stanza successiva resta nello stesso riferimento.
    func fineStanza() {
        vista.captureSession.stop(pauseARSession: false)
        stato.fase = .elaborazione
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error { stato.errore = error.localizedDescription }
        stato.stanze.append(processedResult)
        stato.fase = .rivedi
    }
}

struct VistaScansione: UIViewControllerRepresentable {
    let stato: StatoScansione
    func makeUIViewController(context: Context) -> ScanVC { ScanVC(stato: stato) }
    func updateUIViewController(_ vc: ScanVC, context: Context) {}
}

struct SchermataScansione: View {
    let fine: ([CapturedRoom]) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stato = StatoScansione()

    var body: some View {
        ZStack {
            VistaScansione(stato: stato).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if !stato.stanze.isEmpty {
                        Label("\(stato.stanze.count)", systemImage: "square.split.bottomrightquarter")
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                Spacer()
                if let e = stato.errore {
                    Text(e).font(.footnote).padding(10).background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
                Group {
                    switch stato.fase {
                    case .avvio:
                        ProgressView()
                    case .scansione:
                        VStack(spacing: 10) {
                            Text("Inquadra pareti, angoli, porte e finestre. Muoviti piano.")
                                .font(.footnote).foregroundStyle(.white.opacity(0.85))
                            Button { withAnimation(.easeInOut(duration: 0.2)) { stato.vc?.fineStanza() } } label: {
                                Label("Fine stanza", systemImage: "stop.fill").font(.headline)
                                    .padding(.horizontal, 26).padding(.vertical, 14)
                                    .background(Tema.cAccento, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                            }
                            .buttonStyle(EffettoPremuto())
                        }
                    case .elaborazione:
                        HStack(spacing: 10) { ProgressView(); Text("Ricostruzione della stanza…") }
                            .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    case .rivedi:
                        HStack(spacing: 12) {
                            Button { withAnimation(.easeInOut(duration: 0.2)) { stato.vc?.avvia() } } label: {
                                Label("Altra stanza", systemImage: "plus").font(.headline)
                                    .padding(.horizontal, 20).padding(.vertical, 14)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            Button { fine(stato.stanze); dismiss() } label: {
                                Label("Usa \(stato.stanze.count == 1 ? "la stanza" : "\(stato.stanze.count) stanze")",
                                      systemImage: "checkmark").font(.headline)
                                    .padding(.horizontal, 20).padding(.vertical, 14)
                                    .background(Tema.cAccento, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(EffettoPremuto())
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: stato.fase)
            }
            .padding()
        }
    }
}
