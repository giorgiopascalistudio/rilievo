import SwiftUI
import UIKit

/// Stile "blueprint": fondo blu notte, muri chiari, quote misurate verdi e stimate ambra.
enum Tema {
    static let fondo = UIColor(red: 0.082, green: 0.086, blue: 0.094, alpha: 1)
    static let fondo2 = UIColor(red: 0.118, green: 0.122, blue: 0.133, alpha: 1)
    static let griglia = UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)
    static let muro = UIColor(red: 0.62, green: 0.64, blue: 0.67, alpha: 1)
    static let pavimento = UIColor(red: 0.125, green: 0.13, blue: 0.14, alpha: 1)
    static let accento = UIColor(red: 0.36, green: 0.58, blue: 0.92, alpha: 1)
    static let misurato = UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
    static let stimato = UIColor(red: 0.86, green: 0.66, blue: 0.38, alpha: 1)
    static let controllo = UIColor(red: 0.60, green: 0.62, blue: 0.70, alpha: 1)
    static let testo = UIColor(white: 0.96, alpha: 1)
    static let testo2 = UIColor(white: 0.62, alpha: 1)

    static var cAccento: Color { Color(uiColor: accento) }
    static var cMisurato: Color { Color(uiColor: misurato) }
    static var cQuotato: Color { Color(red: 0.42, green: 0.74, blue: 0.52) }
    static var bordo: Color { Color.white.opacity(0.09) }
    static var cStimato: Color { Color(uiColor: stimato) }
    static var cControllo: Color { Color(uiColor: controllo) }
    static var cFondo: Color { Color(uiColor: fondo) }
    static var cFondo2: Color { Color(uiColor: fondo2) }

    static var sfondo: some View {
        cFondo.ignoresSafeArea()
    }
}

/// Anello di avanzamento delle quote.
struct AnelloAvanzamento: View {
    var valore: Double
    var spessore: CGFloat = 5
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: spessore)
            Circle()
                .trim(from: 0, to: max(0.001, valore))
                .stroke(Tema.cAccento, style: StrokeStyle(lineWidth: spessore, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: valore)
        }
    }
}

/// Miniatura della pianta per le schede dell'elenco.
struct Miniatura: View {
    let rilievo: Rilievo
    var body: some View {
        Canvas { ctx, size in
            let pts = rilievo.stanze.flatMap(\.punti)
            let box = Geo.riquadro(pts)
            guard !pts.isEmpty, box.width > 0.01 || box.height > 0.01 else { return }
            let k = min((size.width - 24) / max(box.width, 0.5), (size.height - 24) / max(box.height, 0.5))
            func t(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x - box.midX) * k + size.width / 2, y: (p.y - box.midY) * k + size.height / 2)
            }
            for s in rilievo.stanze where s.n >= 3 {
                var path = Path()
                path.addLines(s.punti.map(t))
                path.closeSubpath()
                ctx.fill(path, with: .color(Color.white.opacity(0.05)))
                ctx.stroke(path, with: .color(Color.white.opacity(0.8)), lineWidth: 1.5)
            }
        }
    }
}

struct EffettoPremuto: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
