import SwiftUI

func chiudiTastiera() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Riga con stima (grigio) e campo per la misura del distanziometro.
struct CampoQuota: View {
    let titolo: String
    let quota: Quota
    var nota: String? = nil
    var maxMetri: Double = 60
    let imposta: (Double?) -> Void

    @State private var testo = ""
    @FocusState private var fuoco: Bool
    @State private var conferma = 0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titolo).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text("≈ " + Fmt.m(quota.stimato)).foregroundStyle(Tema.cStimato.opacity(0.85))
                    if let nota { Text(nota).foregroundStyle(.secondary) }
                }
                .font(.caption.monospacedDigit())
            }
            Spacer(minLength: 4)
            TextField("misura", text: $testo)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(width: 96)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(fuoco ? 0.12 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(fuoco ? Tema.cAccento : .clear, lineWidth: 1.5))
                .focused($fuoco)
                .onSubmit(commit)
            Image(systemName: quota.quotato ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(quota.quotato ? Tema.cQuotato : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
        }
        .animation(.easeOut(duration: 0.2), value: fuoco)
        .onAppear { testo = quota.misurato.map(Fmt.m) ?? "" }
        .onChange(of: quota.misurato) { _, v in if !fuoco { testo = v.map(Fmt.m) ?? "" } }
        .onChange(of: fuoco) { _, f in if !f { commit() } }
    }

    private func commit() {
        let t = testo.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            if quota.misurato != nil { imposta(nil) }
            return
        }
        guard let v = Fmt.numero(t, maxMetri: maxMetri) else {
            testo = quota.misurato.map(Fmt.m) ?? ""
            return
        }
        testo = Fmt.m(v)
        if v != quota.misurato {
            imposta(v)
            conferma += 1
        }
    }
}

struct Ispettore: View {
    @ObservedObject var model: EditorModel

    private var suStanza: Bool { if case .stanza = model.selezione { return true }; return false }

    var body: some View {
        NavigationStack {
            Form { contenuto }
                .scrollContentBackground(.hidden)
                .background(Tema.cFondo)
                .navigationTitle(titolo)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let id = model.selezione.stanzaID, !suStanza {
                            Button { withAnimation(.easeInOut(duration: 0.2)) { model.selezione = .stanza(id) } } label: {
                                Label("Stanza", systemImage: "chevron.backward")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { withAnimation(.easeInOut(duration: 0.2)) { model.selezione = .nessuna } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Fine") { chiudiTastiera() }.fontWeight(.semibold)
                    }
                }
                .animation(.snappy, value: model.selezione)
        }
        .presentationDetents([.fraction(0.45), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        .presentationBackground(Tema.cFondo)
    }

    private var titolo: String {
        switch model.selezione {
        case .nessuna: return ""
        case .stanza(let id): return model.stanza(id)?.nome ?? ""
        case .lato(let id, let i): return "Lato " + (model.stanza(id).map { $0.nomeLato(i) } ?? "")
        case .vertice(let id, let k): return "Vertice " + (model.stanza(id).map { $0.lettera(k) } ?? "")
        case .apertura(let id, let a): return model.stanza(id)?.aperture.first { $0.id == a }?.tipo.nome ?? ""
        case .diagonale(let id, let a, let b):
            return "Diagonale " + (model.stanza(id).map { $0.lettera(a) + "–" + $0.lettera(b) } ?? "")
        }
    }

    @ViewBuilder private var contenuto: some View {
        switch model.selezione {
        case .nessuna:
            Text("Tocca una stanza, un muro o un'apertura.")
        case .stanza(let id):
            if let s = model.stanza(id) { SchedaStanza(model: model, s: s) }
        case .lato(let id, let i):
            if let s = model.stanza(id), i < s.n { SchedaLato(model: model, s: s, i: i) }
        case .vertice(let id, let k):
            if let s = model.stanza(id), k < s.n { SchedaVertice(model: model, s: s, k: k) }
        case .apertura(let id, let aid):
            if let s = model.stanza(id), let a = s.aperture.first(where: { $0.id == aid }) {
                SchedaApertura(model: model, s: s, a: a)
            }
        case .diagonale(let id, let a, let b):
            if let s = model.stanza(id), a < s.n, b < s.n { SchedaDiagonale(model: model, s: s, a: a, b: b) }
        }
    }
}

// MARK: - Stanza

struct SchedaStanza: View {
    @ObservedObject var model: EditorModel
    let s: Stanza

    var body: some View {
        let st = Risolutore.stato(s)
        let sugg = Risolutore.diagonaliDaMisurare(s)
        Section {
            HStack(spacing: 16) {
                ZStack {
                    AnelloAvanzamento(valore: st.avanzamento, spessore: 6)
                    Image(systemName: st.bloccata ? "lock.fill" : "lock.open")
                        .font(.title3)
                        .foregroundStyle(st.bloccata ? Tema.cQuotato : Tema.cStimato)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(st.bloccata ? "Forma bloccata" : "Forma da bloccare").font(.headline)
                    Text("Lati \(st.latiQuotati)/\(st.lati) · diagonali \(min(st.diagMisurate, st.diagNecessarie))/\(st.diagNecessarie)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Text(Fmt.area(s.area)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.25), value: st.latiQuotati + st.diagMisurate)
            TextField("Nome stanza", text: Binding(get: { s.nome },
                                                   set: { v in model.modificaStanza(s.id, annullabile: false) { $0.nome = v } }))
            if st.scarto > 0.01 {
                Label("Le misure non tornano: scarto \(Fmt.cm(st.scarto))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(st.fuoriSquadra) { f in
                let lmin = min(s.lunghezzaGeom((f.id - 1 + s.n) % s.n), s.lunghezzaGeom(f.id))
                LabeledContent("Fuori squadra in \(s.lettera(f.id))",
                               value: "\(Fmt.gradi(f.gradi)) · \(Fmt.cm(lmin * sin(abs(f.scarto) * .pi / 180))) su \(Fmt.m(lmin)) m")
                    .foregroundStyle(Tema.cStimato)
            }
        }

        Section {
            ForEach(0..<s.n, id: \.self) { i in
                CampoQuota(titolo: s.nomeLato(i), quota: s.lati[i].lunghezza) { v in
                    model.modificaStanza(s.id, risolvi: true) { $0.lati[i].lunghezza.misurato = v }
                }
            }
        } header: {
            Label("Lati", systemImage: "ruler")
        } footer: {
            Text("Scrivi in metri (3,42) o in centimetri (342). Con la Pencil puoi scrivere a mano nel campo.")
        }

        if s.n >= 4 {
            Section {
                ForEach(s.diagonali.filter { $0.a < s.n && $0.b < s.n }) { d in
                    CampoQuota(titolo: s.lettera(d.a) + "–" + s.lettera(d.b),
                               quota: Quota(s.distanza(d.a, d.b), misurato: d.misurato), nota: "misurata", maxMetri: 80) { v in
                        model.setDiagonale(s.id, d.a, d.b, v)
                    }
                }
                ForEach(sugg) { g in
                    CampoQuota(titolo: s.lettera(g.a) + "–" + s.lettera(g.b), quota: Quota(s.distanza(g.a, g.b)),
                               nota: g.controllo ? "controllo, facoltativa" : "da misurare", maxMetri: 80) { v in
                        model.setDiagonale(s.id, g.a, g.b, v)
                    }
                }
            } header: {
                Label("Diagonali", systemImage: "line.diagonal")
            } footer: {
                Text("Per bloccare una stanza di \(s.n) lati servono \(s.n - 3) diagonali (tratteggio arancione). Quella viola è di controllo: se non torna, l'app ti avvisa. Sono scelte evitando gli arredi rilevati.")
            }
        }

        Section {
            Picker("Copertura", selection: Binding(get: { s.soffitto.tipo },
                                                   set: { v in model.modificaStanza(s.id) { $0.soffitto.tipo = v } })) {
                ForEach(TipoSoffitto.allCases) { Text($0.nome).tag($0) }
            }
            switch s.soffitto.tipo {
            case .piano:
                CampoQuota(titolo: "Altezza soffitto", quota: s.soffitto.altezza, maxMetri: 15) { v in
                    model.modificaStanza(s.id) { $0.soffitto.altezza.misurato = v }
                }
            case .inclinato:
                CampoQuota(titolo: "Altezza minima", quota: s.soffitto.altezza, maxMetri: 15) { v in
                    model.modificaStanza(s.id) { $0.soffitto.altezza.misurato = v }
                }
                CampoQuota(titolo: "Altezza massima", quota: s.soffitto.altezzaMax, maxMetri: 15) { v in
                    model.modificaStanza(s.id) { $0.soffitto.altezzaMax.misurato = v }
                }
            default:
                CampoQuota(titolo: "Imposta da terra", quota: s.soffitto.altezza, nota: "dove nasce la volta", maxMetri: 15) { v in
                    model.modificaStanza(s.id) { $0.soffitto.altezza.misurato = v }
                }
                CampoQuota(titolo: "Chiave da terra", quota: s.soffitto.altezzaMax, nota: "punto più alto", maxMetri: 15) { v in
                    model.modificaStanza(s.id) { $0.soffitto.altezzaMax.misurato = v }
                }
                LabeledContent("Freccia", value: Fmt.m(s.soffitto.altezzaMax.valore - s.soffitto.altezza.valore) + " m")
            }
            if s.soffitto.tipo.haAsse {
                Picker(s.soffitto.tipo == .inclinato ? "Lato più basso" : "Asse parallelo al lato",
                       selection: Binding(get: { min(s.soffitto.latoAsse, s.n - 1) },
                                          set: { v in model.modificaStanza(s.id) { $0.soffitto.latoAsse = v } })) {
                    ForEach(0..<s.n, id: \.self) { i in Text(s.nomeLato(i)).tag(i) }
                }
            }
        } header: {
            Label("Altezze e copertura", systemImage: "arrow.up.and.down")
        }

        Section {
            ForEach(s.aperture) { a in
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.selezione = .apertura(s.id, a.id) } } label: {
                    HStack {
                        Image(systemName: a.completa ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(a.completa ? Tema.cQuotato : Tema.cStimato)
                        Text(a.tipo.nome)
                        Text(s.nomeLato(a.lato)).foregroundStyle(.secondary)
                        Spacer()
                        Text(a.sintesi).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }
            if s.aperture.isEmpty {
                Text("Nessuna. Scegli Porta o Finestra in basso e tocca un muro.").foregroundStyle(.secondary)
            }
        } header: {
            Label("Porte e finestre", systemImage: "door.left.hand.open")
        }

        Section {
            CampoQuota(titolo: "Spessore muri (tutti)", quota: s.lati[0].spessore, maxMetri: 2) { v in
                model.modificaStanza(s.id) { x in for i in x.lati.indices { x.lati[i].spessore.misurato = v } }
            }
        } header: {
            Label("Muri", systemImage: "square.dashed")
        } footer: {
            Text("Lo spessore del singolo muro si cambia toccando il lato.")
        }

        Section {
            Button(role: .destructive) { model.eliminaStanza(s.id) } label: {
                Label("Elimina stanza", systemImage: "trash")
            }
        }
    }
}

// MARK: - Lato, vertice, apertura, diagonale

struct SchedaLato: View {
    @ObservedObject var model: EditorModel
    let s: Stanza
    let i: Int

    var body: some View {
        let j = (i + 1) % s.n
        let st = Risolutore.stato(s)
        Section {
            CampoQuota(titolo: "Lunghezza", quota: s.lati[i].lunghezza) { v in
                model.modificaStanza(s.id, risolvi: true) { $0.lati[i].lunghezza.misurato = v }
            }
            CampoQuota(titolo: "Spessore muro", quota: s.lati[i].spessore, maxMetri: 2) { v in
                model.modificaStanza(s.id) { $0.lati[i].spessore.misurato = v }
            }
        } header: {
            Text("Misure")
        }
        Section {
            LabeledContent("Angolo in \(s.lettera(i))", value: Fmt.gradi(Geo.angoloInterno(s.punti, i)))
            LabeledContent("Angolo in \(s.lettera(j))", value: Fmt.gradi(Geo.angoloInterno(s.punti, j)))
        } header: {
            Text("Angoli")
        } footer: {
            Text(st.bloccata ? "Angoli ricavati dalle misure." : "Angoli ancora stimati: quota lati e diagonali per conoscerli.")
        }
        Section("Aperture su questo lato") {
            ForEach(s.aperture.filter { $0.lato == i }) { a in
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.selezione = .apertura(s.id, a.id) } } label: {
                    LabeledContent(a.tipo.nome, value: a.sintesi)
                }
                .foregroundStyle(.primary)
            }
            Button { model.aggiungiAperturaSuLato(s.id, i, .porta) } label: { Label("Aggiungi porta", systemImage: "plus") }
            Button { model.aggiungiAperturaSuLato(s.id, i, .finestra) } label: { Label("Aggiungi finestra", systemImage: "plus") }
            Button { model.aggiungiAperturaSuLato(s.id, i, .portafinestra) } label: { Label("Aggiungi portafinestra", systemImage: "plus") }
        }
        Section {
            Button { model.dividiLato(s.id, i) } label: { Label("Dividi lato (nuovo vertice)", systemImage: "scissors") }
        }
    }
}

struct SchedaVertice: View {
    @ObservedObject var model: EditorModel
    let s: Stanza
    let k: Int

    var body: some View {
        Section {
            LabeledContent("Angolo interno", value: Fmt.gradi(Geo.angoloInterno(s.punti, k)))
        } footer: {
            Text("Trascina il vertice per correggere la forma: le misure già prese restano e la pianta si riadatta.")
        }
        Section {
            Button(role: .destructive) { model.eliminaVertice(s.id, k) } label: {
                Label("Elimina vertice", systemImage: "minus.circle")
            }
            .disabled(s.n <= 3)
        }
    }
}

struct SchedaApertura: View {
    @ObservedObject var model: EditorModel
    let s: Stanza
    let a: Apertura

    private func mod(_ corpo: @escaping (inout Apertura) -> Void) { model.modificaApertura(s.id, a.id, corpo) }

    var body: some View {
        let L = s.lunghezzaGeom(a.lato)
        let fine = s.lettera((a.lato + 1) % s.n)
        Section {
            Picker("Tipo", selection: Binding(get: { a.tipo }, set: { v in mod { $0.tipo = v } })) {
                ForEach(TipoApertura.allCases) { Text($0.sigla).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(a.tipo.nome + " sul lato " + s.nomeLato(a.lato))
        }
        Section {
            CampoQuota(titolo: "Distanza da \(s.lettera(a.lato))", quota: a.distanza, nota: "dall'angolo al vano") { v in
                mod { $0.distanza.misurato = v }
            }
            CampoQuota(titolo: "Larghezza vano", quota: a.larghezza, maxMetri: 10) { v in
                mod { $0.larghezza.misurato = v }
            }
            LabeledContent("Resto fino a \(fine)", value: Fmt.m(L - a.distanza.valore - a.larghezza.valore) + " m")
        } header: {
            Label("In pianta", systemImage: "ruler")
        }
        Section {
            CampoQuota(titolo: a.tipo == .finestra ? "Davanzale da terra" : "Soglia da terra", quota: a.davanzale, maxMetri: 10) { v in
                mod { $0.davanzale.misurato = v }
            }
            CampoQuota(titolo: "Altezza vano", quota: a.altezza, maxMetri: 10) { v in
                mod { $0.altezza.misurato = v }
            }
            CampoQuota(titolo: "Architrave da terra",
                       quota: Quota(a.davanzale.valore + a.altezza.valore,
                                    misurato: a.altezza.quotato ? a.davanzale.valore + a.altezza.valore : nil),
                       nota: "ricava l'altezza del vano", maxMetri: 10) { v in
                mod { x in
                    if let v { x.altezza.misurato = max(0, v - x.davanzale.valore) } else { x.altezza.misurato = nil }
                }
            }
            let sopra = (s.soffitto.tipo.volta ? s.soffitto.altezza.valore : s.soffitto.altezza.valore) - a.davanzale.valore - a.altezza.valore
            LabeledContent(s.soffitto.tipo.volta ? "Dall'architrave all'imposta" : "Dall'architrave al soffitto",
                           value: Fmt.m(sopra) + " m")
        } header: {
            Label("Altezze", systemImage: "arrow.up.and.down")
        }
        if a.tipo.haAnta {
            Section("Anta") {
                Picker("Cerniera", selection: Binding(get: { a.verso }, set: { v in mod { $0.verso = v } })) {
                    Text("verso \(s.lettera(a.lato))").tag(1)
                    Text("verso \(fine)").tag(-1)
                }
                .pickerStyle(.segmented)
                Toggle("Apre verso l'interno", isOn: Binding(get: { a.apreDentro }, set: { v in mod { $0.apreDentro = v } }))
            }
        }
        Section {
            Button(role: .destructive) { model.eliminaApertura(s.id, a.id) } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
    }
}

struct SchedaDiagonale: View {
    @ObservedObject var model: EditorModel
    let s: Stanza
    let a: Int
    let b: Int

    var body: some View {
        let esistente = s.diagonali.first { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
        Section {
            CampoQuota(titolo: "Misura", quota: Quota(s.distanza(a, b), misurato: esistente?.misurato), maxMetri: 80) { v in
                model.setDiagonale(s.id, a, b, v)
            }
        } footer: {
            Text("Da spigolo a spigolo, alla stessa altezza da terra. Con tutti i lati e le diagonali la forma si blocca e l'app calcola i fuori squadra.")
        }
    }
}
