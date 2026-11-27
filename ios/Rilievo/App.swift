import SwiftUI
import UniformTypeIdentifiers
import RoomPlan

@main
struct RilievoApp: App {
    @StateObject private var archivio = Archivio()
    @Environment(\.scenePhase) private var fase
    private let orologio = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup {
            Elenco()
                .environmentObject(archivio)
                .preferredColorScheme(.dark)
                .tint(Tema.cAccento)
                .onAppear { Sincro.condivisa.sincronizza(archivio) }
                .onReceive(orologio) { _ in if fase == .active { Sincro.condivisa.sincronizza(archivio) } }
        }
        .onChange(of: fase) { _, f in if f == .active || f == .background { Sincro.condivisa.sincronizza(archivio) } }
    }
}

struct RilievoAperto: Identifiable { let id: UUID; var scansiona = false }

struct Elenco: View {
    @EnvironmentObject private var archivio: Archivio
    @ObservedObject private var sincro = Sincro.condivisa
    @State private var aperto: RilievoAperto?
    @State private var sceltaCartella = false
    @State private var impostazioni = false
    @State private var daEliminare: Rilievo?
    @State private var comparso = false

    private let colonne = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                Tema.sfondo
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        testata
                        statoSincro
                        LazyVGrid(columns: colonne, spacing: 12) {
                            nuovoRilievo
                            ForEach(Array(archivio.rilievi.enumerated()), id: \.element.id) { k, r in
                                Button { aperto = RilievoAperto(id: r.id) } label: { Scheda(rilievo: r) }
                                    .buttonStyle(EffettoPremuto())
                                    .contextMenu {
                                        Button(role: .destructive) { daEliminare = r } label: { Label("Elimina", systemImage: "trash") }
                                    }
                                    .opacity(comparso ? 1 : 0)
                                    .animation(.easeOut(duration: 0.25).delay(Double(min(k, 8)) * 0.03), value: comparso)
                            }
                        }
                    }
                    .padding(20)
                }
                .refreshable { Sincro.condivisa.sincronizza(archivio) }
            }
            .fullScreenCover(item: $aperto) { a in
                if let r = archivio.rilievo(a.id) {
                    NavigationStack { EditorView(rilievo: r, archivio: archivio, scansiona: a.scansiona) }
                        .preferredColorScheme(.dark)
                        .tint(Tema.cAccento)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                comparso = true
                if aperto == nil, let r = Prova.rilievo() {
                    archivio.salva(r)
                    aperto = RilievoAperto(id: r.id)
                }
            }
            .fileImporter(isPresented: $sceltaCartella, allowedContentTypes: [.folder]) { esito in
                if case .success(let url) = esito {
                    Sincro.condivisa.imposta(url)
                    Sincro.condivisa.sincronizza(archivio)
                }
            }
            .confirmationDialog("Eliminare il rilievo?", isPresented: Binding(get: { daEliminare != nil }, set: { if !$0 { daEliminare = nil } }),
                                titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let r = daEliminare { withAnimation(.easeInOut(duration: 0.2)) { archivio.elimina(r.id) } }
                }
            } message: {
                Text("Viene eliminato anche dall'altro dispositivo sincronizzato.")
            }
        }
    }

    private var testata: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rilievi")
                    .font(.largeTitle.weight(.bold))
                Text("\(archivio.rilievi.count) lavori").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var statoSincro: some View {
        Button { sceltaCartella = true } label: {
            HStack(spacing: 12) {
                Image(systemName: sincro.attiva ? "icloud.fill" : "icloud.slash")
                    .font(.title3)
                    .foregroundStyle(sincro.attiva ? Tema.cAccento : .secondary)
                    .opacity(sincro.inCorso ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    if sincro.attiva {
                        Text("Sincronizzato con iCloud Drive · \(sincro.nomeCartella)").font(.subheadline.weight(.medium))
                        Text(sincro.errore ?? (sincro.ultima.map { "Ultimo allineamento " + $0.formatted(date: .omitted, time: .shortened) } ?? "In attesa…"))
                            .font(.caption).foregroundStyle(sincro.errore == nil ? Color.secondary : Color.orange)
                    } else {
                        Text("Collega iPhone e iPad").font(.subheadline.weight(.medium))
                        Text("Scegli la stessa cartella di iCloud Drive su entrambi").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Tema.cFondo2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.bordo, lineWidth: 1))
        }
        .buttonStyle(EffettoPremuto())
        .foregroundStyle(.primary)
    }

    private func crea(scansiona: Bool) {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        let r = Rilievo(nome: (scansiona ? "Scansione " : "Rilievo ") + f.string(from: Date()))
        archivio.salva(r)
        aperto = RilievoAperto(id: r.id, scansiona: scansiona)
    }

    private var nuovoRilievo: some View {
        VStack(spacing: 12) {
            if Scanner.supportata {
                Button { crea(scansiona: true) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "camera.metering.matrix")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Tema.cAccento, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scansiona con LiDAR").font(.headline)
                            Text("Nuvola di punti semplificata in pianta: pareti, porte, finestre, altezze")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(Tema.cFondo2, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.bordo, lineWidth: 1))
                }
                .buttonStyle(EffettoPremuto())
            }
            Button { crea(scansiona: false) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 21, weight: .regular))
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disegna la pianta").font(.headline)
                        Text("A mano libera con la Pencil o col dito").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 84)
                .background(Tema.cFondo2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.bordo, lineWidth: 1))
            }
            .buttonStyle(EffettoPremuto())
        }
        .foregroundStyle(.primary)
    }
}

struct Scheda: View {
    let rilievo: Rilievo
    var body: some View {
        let q = rilievo.quoteFatte
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Tema.cFondo)
                if rilievo.stanze.isEmpty {
                    Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(.tertiary)
                } else {
                    Miniatura(rilievo: rilievo)
                }
            }
            .frame(height: 120)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rilievo.nome).font(.headline).lineLimit(1)
                    Text("\(rilievo.stanze.count) stanze · \(Fmt.area(rilievo.superficie))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(rilievo.modificato.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                ZStack {
                    AnelloAvanzamento(valore: q.totali == 0 ? 0 : Double(q.fatte) / Double(q.totali), spessore: 4)
                    Text(q.totali == 0 ? "–" : "\(Int(Double(q.fatte) / Double(q.totali) * 100))")
                        .font(.caption2.monospacedDigit().weight(.bold))
                }
                .frame(width: 38, height: 38)
            }
        }
        .padding(10)
        .background(Tema.cFondo2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.bordo, lineWidth: 1))
        .foregroundStyle(.primary)
    }
}
