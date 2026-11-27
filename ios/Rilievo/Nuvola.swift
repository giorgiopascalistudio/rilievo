import ARKit
import SceneKit
import SwiftUI

/// Scansione a nuvola di punti con il LiDAR (profondità di scena di ARKit).
/// I punti si accumulano in una griglia di 2 cm per stanza; la sessione AR resta la stessa
/// fra una stanza e l'altra, quindi le stanze escono già allineate fra loro.
final class Scanner: NSObject, ObservableObject, ARSessionDelegate {
    enum Fase: Equatable { case scansione, elaborazione, rivedi, pausa }

    @Published var fase: Fase = .scansione
    @Published var numeroPunti = 0
    @Published var stanze: [Stanza] = []
    @Published var messaggio: String?
    @Published var tracking = "Inizializzazione…"

    let vista = ARSCNView(frame: .zero)
    private let coda = DispatchQueue(label: "nuvola", qos: .userInitiated)
    private var voxel: [Int64: SIMD3<Float>] = [:]
    private var camere: [SIMD3<Float>] = []
    private var tutte: [[SIMD3<Float>]] = []
    private var ultimo: TimeInterval = 0
    private var ultimaVista: TimeInterval = 0
    private var occupato = false
    private let nodo = SCNNode()
    private let lato: Float = 0.02
    private let massimoPunti = 2_500_000

    static var supportata: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    override init() {
        super.init()
        vista.session.delegate = self
        vista.session.delegateQueue = coda
        vista.automaticallyUpdatesLighting = false
        vista.scene.rootNode.addChildNode(nodo)
    }

    func avvia() {
        let c = ARWorldTrackingConfiguration()
        c.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        c.worldAlignment = .gravity
        vista.session.run(c)
    }

    func ferma() { vista.session.pause() }

    func nuovaStanza() {
        coda.async {
            self.voxel.removeAll(keepingCapacity: true)
            self.camere.removeAll()
            DispatchQueue.main.async {
                self.numeroPunti = 0
                self.nodo.geometry = nil
                self.fase = .scansione
            }
        }
    }

    /// Chiude la stanza corrente: semplifica la nuvola in una pianta.
    func fineStanza(nome: String) {
        fase = .elaborazione
        coda.async {
            let punti = Array(self.voxel.values)
            let cam = self.camere
            self.tutte.append(punti)
            DispatchQueue.global(qos: .userInitiated).async {
                let esito = Semplifica.stanza(punti: punti, camere: cam, nome: nome)
                DispatchQueue.main.async {
                    if let e = esito {
                        self.stanze.append(e.stanza)
                        self.messaggio = "\(nome): \(e.pareti) pareti, \(e.aperture) aperture riconosciute"
                    } else {
                        self.messaggio = "Non riesco a chiudere il perimetro: inquadra meglio pareti e angoli, poi riprova"
                    }
                    self.fase = .rivedi
                }
            }
        }
    }

    /// Nuvola completa (tutte le stanze) in PLY binario, per CloudCompare, ReCap ecc.
    func salvaPLY(in url: URL) {
        let punti = tutte.flatMap { $0 }
        guard !punti.isEmpty else { return }
        var d = Data("ply\nformat binary_little_endian 1.0\nelement vertex \(punti.count)\nproperty float x\nproperty float y\nproperty float z\nend_header\n".utf8)
        d.reserveCapacity(d.count + punti.count * 12)
        for p in punti {
            // in uscita: X est, Y nord (= -z ARKit), Z quota
            var v = SIMD3<Float>(p.x, -p.z, p.y)
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0.prefix(12)) }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url)
    }

    // MARK: ARSessionDelegate (sulla coda "nuvola")

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let t: String
        switch camera.trackingState {
        case .normal: t = ""
        case .notAvailable: t = "Tracciamento non disponibile"
        case .limited(let r):
            switch r {
            case .excessiveMotion: t = "Muoviti più lentamente"
            case .insufficientFeatures: t = "Poca luce o superfici uniformi"
            case .initializing: t = "Inizializzazione…"
            case .relocalizing: t = "Riallineamento…"
            @unknown default: t = "Tracciamento limitato"
            }
        }
        DispatchQueue.main.async { self.tracking = t }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !occupato, frame.timestamp - ultimo > 0.12 else { return }
        guard case .normal = frame.camera.trackingState else { return }
        var inScansione = false
        DispatchQueue.main.sync { inScansione = self.fase == .scansione }
        guard inScansione, voxel.count < massimoPunti else { return }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth, let conf = depth.confidenceMap else { return }
        occupato = true
        ultimo = frame.timestamp
        integra(frame, depth.depthMap, conf)
        let c = frame.camera.transform.columns.3
        camere.append(SIMD3(c.x, c.y, c.z))
        occupato = false
        if frame.timestamp - ultimaVista > 0.5 {
            ultimaVista = frame.timestamp
            aggiornaVista()
        }
    }

    private func integra(_ frame: ARFrame, _ dm: CVPixelBuffer, _ cm: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        CVPixelBufferLockBaseAddress(cm, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(dm, .readOnly)
            CVPixelBufferUnlockBaseAddress(cm, .readOnly)
        }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)
        guard let pd = CVPixelBufferGetBaseAddress(dm), let pc = CVPixelBufferGetBaseAddress(cm) else { return }
        let rd = CVPixelBufferGetBytesPerRow(dm), rc = CVPixelBufferGetBytesPerRow(cm)
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let fx = K[0][0] * sx, fy = K[1][1] * sy, cx = K[2][0] * sx, cy = K[2][1] * sy
        let T = frame.camera.transform
        var v = 0
        while v < h {
            let rigaD = pd.advanced(by: v * rd).assumingMemoryBound(to: Float32.self)
            let rigaC = pc.advanced(by: v * rc).assumingMemoryBound(to: UInt8.self)
            var u = 0
            while u < w {
                let d = rigaD[u]
                if rigaC[u] >= 2, d > 0.25, d < 4.5 {
                    let x = (Float(u) - cx) * d / fx
                    let y = (Float(v) - cy) * d / fy
                    let p = T * SIMD4<Float>(x, -y, -d, 1)
                    let k = (Int64((p.x / lato).rounded(.down)) + 0x100000) << 42
                        | (Int64((p.y / lato).rounded(.down)) + 0x100000) << 21
                        | (Int64((p.z / lato).rounded(.down)) + 0x100000)
                    if voxel[k] == nil { voxel[k] = SIMD3(p.x, p.y, p.z) }
                }
                u += 2
            }
            v += 2
        }
    }

    /// Anteprima dei punti sopra la fotocamera, colorati per quota.
    private func aggiornaVista() {
        let tutti = Array(voxel.values)
        let n = tutti.count
        let passo = max(1, n / 250_000)
        var vertici: [SCNVector3] = []
        var colori: [SIMD3<Float>] = []
        vertici.reserveCapacity(n / passo + 1)
        colori.reserveCapacity(n / passo + 1)
        let minY = camere.map(\.y).min().map { $0 - 1.6 } ?? -1.5
        var i = 0
        while i < n {
            let p = tutti[i]
            vertici.append(SCNVector3(p.x, p.y, p.z))
            let t = max(0, min(1, (p.y - minY) / 3))
            colori.append(SIMD3(0.15 + 0.85 * t, 0.85 - 0.3 * t, 0.95 - 0.6 * t))
            i += passo
        }
        DispatchQueue.main.async {
            self.numeroPunti = n
            guard !vertici.isEmpty else { return }
            let sv = SCNGeometrySource(vertices: vertici)
            let dc = colori.withUnsafeBufferPointer { Data(buffer: $0) }
            let sc = SCNGeometrySource(data: dc, semantic: .color, vectorCount: colori.count, usesFloatComponents: true,
                                       componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD3<Float>>.stride)
            let indici = (0..<Int32(vertici.count)).map { $0 }
            let el = SCNGeometryElement(indices: indici, primitiveType: .point)
            el.pointSize = 3
            el.minimumPointScreenSpaceRadius = 1.5
            el.maximumPointScreenSpaceRadius = 3
            let g = SCNGeometry(sources: [sv, sc], elements: [el])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.white
            g.materials = [m]
            self.nodo.geometry = g
        }
    }
}

struct VistaAR: UIViewRepresentable {
    let scanner: Scanner
    func makeUIView(context: Context) -> ARSCNView { scanner.vista }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

struct SchermataNuvola: View {
    let primoNumero: Int
    let fine: ([Stanza], URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = Scanner()

    private var nomeStanza: String { "Stanza \(primoNumero + scanner.stanze.count)" }

    var body: some View {
        ZStack {
            VistaAR(scanner: scanner).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Button { scanner.ferma(); dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(punti, systemImage: "circle.grid.3x3.fill")
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.snappy, value: scanner.numeroPunti)
                        if !scanner.stanze.isEmpty {
                            Text("\(scanner.stanze.count) stanze pronte").font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                if !scanner.tracking.isEmpty && scanner.fase == .scansione {
                    Text(scanner.tracking).font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.orange.opacity(0.85), in: Capsule())
                        .transition(.opacity)
                }
                Spacer()
                if let m = scanner.messaggio, scanner.fase == .rivedi {
                    Text(m).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                comandi
            }
            .padding()
            .animation(.easeInOut(duration: 0.25), value: scanner.fase)
        }
        .onAppear { scanner.avvia() }
        .onDisappear { scanner.ferma() }
    }

    private var punti: String {
        let n = scanner.numeroPunti
        return n >= 1_000_000 ? String(format: "%.1f M punti", Double(n) / 1e6).replacingOccurrences(of: ".", with: ",")
                              : "\(n / 1000)k punti"
    }

    @ViewBuilder private var comandi: some View {
        switch scanner.fase {
        case .scansione:
            VStack(spacing: 10) {
                Text("\(nomeStanza): cammina lungo le pareti e inquadra angoli, porte, finestre e soffitto")
                    .font(.footnote).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
                Button { scanner.fineStanza(nome: nomeStanza) } label: {
                    Label("Fine stanza", systemImage: "stop.fill").font(.headline)
                        .padding(.horizontal, 26).padding(.vertical, 14)
                        .background(Tema.cAccento, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                }
                .buttonStyle(EffettoPremuto())
                .disabled(scanner.numeroPunti < 5000)
            }
        case .elaborazione:
            HStack(spacing: 10) { ProgressView(); Text("Semplificazione della nuvola…") }
                .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .rivedi, .pausa:
            HStack(spacing: 12) {
                Button { scanner.nuovaStanza() } label: {
                    Label("Altra stanza", systemImage: "plus").font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                if !scanner.stanze.isEmpty {
                    Button {
                        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Nuvole/\(UUID().uuidString).ply")
                        scanner.salvaPLY(in: url)
                        scanner.ferma()
                        fine(scanner.stanze, url)
                        dismiss()
                    } label: {
                        Label("Usa \(scanner.stanze.count == 1 ? "la stanza" : "\(scanner.stanze.count) stanze")",
                              systemImage: "checkmark").font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 14)
                            .background(Tema.cAccento, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(EffettoPremuto())
        }
    }
}
