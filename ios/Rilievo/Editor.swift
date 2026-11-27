import SwiftUI
import RoomPlan

struct FileCondivisi: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct Condividi: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct EditorView: View {
    @StateObject private var model: EditorModel
    @ObservedObject private var sincro = Sincro.condivisa
    @State private var ispettore = false
    @State private var scansione = false
    @State private var nuvola = false
    @State private var condivisi: FileCondivisi?
    @State private var rinomina = false
    @State private var nuovoNome = ""
    @Namespace private var ns
    @Environment(\.dismiss) private var chiudi

    private let scansionaSubito: Bool

    init(rilievo: Rilievo, archivio: Archivio, scansiona: Bool = false) {
        _model = StateObject(wrappedValue: EditorModel(rilievo: rilievo, archivio: archivio))
        scansionaSubito = scansiona
    }

    var body: some View {
        VistaPianta(model: model)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) { barraInferiore }
            .overlay(alignment: .top) { avviso }
            .navigationTitle(model.rilievo.nome)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar { strumentiAlti }
            .inspector(isPresented: $ispettore) {
                Ispettore(model: model).inspectorColumnWidth(min: 330, ideal: 390, max: 520)
            }
            .onChange(of: model.selezione) { _, s in
                withAnimation(.easeInOut(duration: 0.2)) { ispettore = s != .nessuna }
            }
            .onChange(of: ispettore) { _, v in if !v { model.selezione = .nessuna } }
            .onChange(of: model.avviso) { _, v in
                guard let v else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if model.avviso == v { withAnimation(.easeInOut) { model.avviso = nil } }
                }
            }
            .fullScreenCover(isPresented: $nuvola) {
                SchermataNuvola(primoNumero: model.rilievo.stanze.count + 1) { stanze, ply in
                    model.importaNuvola(stanze, ply: ply)
                }
            }
            .fullScreenCover(isPresented: $scansione) {
                SchermataScansione { stanze in model.importaLidar(stanze) }
            }
            .sheet(item: $condivisi) { f in Condividi(urls: f.urls).presentationDetents([.medium, .large]) }
            .alert("Rinomina rilievo", isPresented: $rinomina) {
                TextField("Nome", text: $nuovoNome)
                Button("Salva") { model.rinomina(nuovoNome) }
                Button("Annulla", role: .cancel) {}
            }
            .onAppear {
                if model.selezione != .nessuna { ispettore = true }
                if scansionaSubito && model.rilievo.stanze.isEmpty { avviaScansione() }
            }
            .overlay(alignment: .top) { if model.rilievo.stanze.isEmpty { vuoto.padding(.top, 60) } }
            .onDisappear { Sincro.condivisa.sincronizza(nil) }
    }

    @ToolbarContentBuilder private var strumentiAlti: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { Sincro.condivisa.sincronizza(nil); chiudi() } label: {
                Label("Rilievi", systemImage: "chevron.backward").labelStyle(.titleAndIcon)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.annulla() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.puoAnnullare)
            if Scanner.supportata {
                Button { avviaScansione() } label: { Image(systemName: "camera.metering.matrix") }
            }
            Menu {
                Toggle(isOn: $model.mostraArredi) { Label("Arredi rilevati", systemImage: "sofa") }
                Toggle(isOn: $model.mostraDiagonali) { Label("Diagonali", systemImage: "line.diagonal") }
                Toggle(isOn: $model.mostraNuvola) { Label("Traccia nuvola di punti", systemImage: "circle.grid.3x3") }
                if RoomCaptureSession.isSupported {
                    Button { scansione = true } label: { Label("Scansione rapida (RoomPlan)", systemImage: "cube.transparent") }
                }
                Button { model.inquadra += 1 } label: { Label("Inquadra tutto", systemImage: "arrow.up.left.and.arrow.down.right") }
                Button { nuovoNome = model.rilievo.nome; rinomina = true } label: { Label("Rinomina", systemImage: "pencil") }
            } label: { Image(systemName: "slider.horizontal.3") }
            Button { condivisi = FileCondivisi(urls: Esporta.file(model.rilievo)) } label: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder private var avviso: some View {
        if let a = model.avviso {
            Text(a)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Tema.cFondo2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tema.bordo, lineWidth: 1))
                .padding(.top, 8)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { model.avviso = nil } }
        }
    }

    private var testoStato: String {
        if model.rilievo.stanze.isEmpty {
            return RoomCaptureSession.isSupported
                ? "Disegna il perimetro con la Pencil oppure scansiona col LiDAR"
                : "Disegna il perimetro con la Pencil o col dito (Disegna)"
        }
        if let id = model.selezione.stanzaID, let s = model.stanza(id) {
            let st = Risolutore.stato(s)
            return "\(s.nome) · lati \(st.latiQuotati)/\(st.lati) · diagonali \(min(st.diagMisurate, st.diagNecessarie))/\(st.diagNecessarie)"
                + (st.bloccata ? " · bloccata" : "")
        }
        if let t = model.strumento.tipoApertura { return "Tocca un muro per inserire: \(t.nome.lowercased())" }
        let q = model.rilievo.quoteFatte
        return "\(model.rilievo.stanze.count) stanze · \(q.fatte)/\(q.totali) quote · tocca una stanza"
    }

    private func avviaScansione() {
        if Scanner.supportata { nuvola = true } else if RoomCaptureSession.isSupported { scansione = true }
    }

    private var vuoto: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.dashed")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Tema.cAccento.opacity(0.7))
            Text("Pianta vuota").font(.title3.weight(.semibold))
            if Scanner.supportata {
                Button { avviaScansione() } label: {
                    Label("Scansiona con LiDAR", systemImage: "camera.metering.matrix")
                        .font(.headline).padding(.horizontal, 22).padding(.vertical, 14)
                        .background(Tema.cAccento, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                }
                .buttonStyle(EffettoPremuto())
            }
            Text("oppure disegna il perimetro con la Pencil\n(col dito: strumento Disegna)")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .background(Tema.cFondo2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tema.bordo, lineWidth: 1))
        .allowsHitTesting(true)
        .transition(.scale.combined(with: .opacity))
    }

    private var barraInferiore: some View {
        VStack(spacing: 8) {
            if Scanner.supportata && !model.rilievo.stanze.isEmpty {
                Button { avviaScansione() } label: {
                    Label("Scansiona altre stanze", systemImage: "camera.metering.matrix")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Tema.cFondo2.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.bordo, lineWidth: 1))
                        .foregroundStyle(Tema.cAccento)
                }
                .buttonStyle(EffettoPremuto())
            }
            Text(testoStato)
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Tema.cFondo2.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tema.bordo, lineWidth: 1))
            HStack(spacing: 2) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.angoliLiberi.toggle() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: model.angoliLiberi ? "angle" : "square.dashed").font(.system(size: 19, weight: .medium))
                        Text(model.angoliLiberi ? "Libero" : "In squadra").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(model.angoliLiberi ? Tema.cStimato : Color.white.opacity(0.75))
                    .frame(width: 62, height: 48)
                }
                .buttonStyle(EffettoPremuto())
                Rectangle().fill(Tema.bordo).frame(width: 1, height: 32)
                ForEach(Strumento.allCases) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { model.strumento = t }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icona).font(.system(size: 19, weight: .medium))
                            Text(t.nome).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(model.strumento == t ? Tema.cAccento : Color.white.opacity(0.75))
                        .frame(width: 56, height: 48)
                        .background {
                            if model.strumento == t {
                                RoundedRectangle(cornerRadius: 8).fill(Tema.cAccento.opacity(0.16))
                                    .matchedGeometryEffect(id: "strumento", in: ns)
                            }
                        }
                    }
                    .buttonStyle(EffettoPremuto())
                }
            }
            .padding(4)
            .background(Tema.cFondo2.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.bordo, lineWidth: 1))
        }
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: model.avviso)
    }
}
