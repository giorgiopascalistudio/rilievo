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
    @State private var condivisi: FileCondivisi?
    @State private var rinomina = false
    @State private var nuovoNome = ""
    @Namespace private var ns
    @Environment(\.dismiss) private var chiudi

    init(rilievo: Rilievo, archivio: Archivio) {
        _model = StateObject(wrappedValue: EditorModel(rilievo: rilievo, archivio: archivio))
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
                withAnimation(.snappy) { ispettore = s != .nessuna }
            }
            .onChange(of: ispettore) { _, v in if !v { model.selezione = .nessuna } }
            .onChange(of: model.avviso) { _, v in
                guard let v else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if model.avviso == v { withAnimation(.easeInOut) { model.avviso = nil } }
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
            .onAppear { if model.selezione != .nessuna { ispettore = true } }
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
            if RoomCaptureSession.isSupported {
                Button { scansione = true } label: { Image(systemName: "camera.metering.matrix") }
            }
            Menu {
                Toggle(isOn: $model.mostraArredi) { Label("Arredi rilevati", systemImage: "sofa") }
                Toggle(isOn: $model.mostraDiagonali) { Label("Diagonali", systemImage: "line.diagonal") }
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
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Tema.cAccento.opacity(0.4), lineWidth: 1))
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

    private var barraInferiore: some View {
        VStack(spacing: 8) {
            Text(testoStato)
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .animation(.snappy, value: testoStato)
            HStack(spacing: 2) {
                ForEach(Strumento.allCases) { t in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { model.strumento = t }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icona).font(.system(size: 19, weight: .medium))
                                .symbolEffect(.bounce, value: model.strumento == t)
                            Text(t.nome).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(model.strumento == t ? Color.black : Color.white.opacity(0.85))
                        .frame(width: 56, height: 50)
                        .background {
                            if model.strumento == t {
                                RoundedRectangle(cornerRadius: 13).fill(Tema.cAccento)
                                    .matchedGeometryEffect(id: "strumento", in: ns)
                                    .shadow(color: Tema.cAccento.opacity(0.6), radius: 8)
                            }
                        }
                    }
                    .buttonStyle(EffettoPremuto())
                }
            }
            .padding(5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .padding(.bottom, 10)
        .animation(.spring, value: model.avviso)
    }
}
