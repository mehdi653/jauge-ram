import AppKit

enum Gauge {

    static func color(for zone: Zone) -> NSColor {
        switch zone {
        case .ok: return NSColor.systemGreen
        case .warn: return NSColor.systemOrange
        case .critical: return NSColor.systemRed
        }
    }

    /// Petite jauge horizontale pour la barre des menus.
    ///
    /// `dark` doit refléter l'apparence effective du bouton : une NSImage est dessinée hors
    /// hiérarchie de vues, donc les couleurs dynamiques (`labelColor`) s'y résolvent toujours
    /// en thème clair et deviendraient invisibles sur une barre sombre.
    static func image(score: Double, zone: Zone, dark: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 12)
        let ink: NSColor = dark ? .white : .black

        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.75, dy: 1.5)
            let radius = inset.height / 2
            let track = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

            ink.withAlphaComponent(0.18).setFill()
            track.fill()

            let ratio = max(0, min(1, score))
            if ratio > 0.001 {
                let width = max(3, inset.width * CGFloat(ratio))
                NSGraphicsContext.saveGraphicsState()
                track.addClip()
                color(for: zone).setFill()
                NSRect(x: inset.minX, y: inset.minY, width: width, height: inset.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Repère du seuil critique (80 %)
            let markX = inset.minX + inset.width * 0.80
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: markX, y: inset.minY + 1))
            mark.line(to: NSPoint(x: markX, y: inset.maxY - 1))
            ink.withAlphaComponent(ratio >= 0.80 ? 0.55 : 0.40).setStroke()
            mark.lineWidth = 1
            mark.stroke()

            ink.withAlphaComponent(0.45).setStroke()
            track.lineWidth = 1
            track.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }

    /// Tout le contenu de l'item : la jauge, puis deux lignes empilées « RAM 80% » et
    /// « CPU 12% ».
    ///
    /// Empilées et non sur une ligne : sur un Mac à encoche, macOS masque sans prévenir
    /// l'item qui ne tient plus à droite de l'encoche. Sur une ligne, l'item faisait 144 pt
    /// et disparaissait ; empilé, il revient à la largeur d'avant le processeur.
    ///
    /// La colonne des valeurs a la largeur de « 100% » : l'item, et tout ce qui est à sa
    /// gauche, ne bouge pas quand les chiffres changent.
    ///
    /// `cpu` : part du processeur, 0...1 ; nil tant que la première mesure n'est pas prête.
    static func statusImage(score: Double, zone: Zone, cpu: Double?, dark: Bool) -> NSImage {
        let ink: NSColor = dark ? .white : .black
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: ink.withAlphaComponent(0.55),
        ]

        let labelWidth = ceil(
            ["RAM", "CPU"].map { ($0 as NSString).size(withAttributes: labelAttrs).width }.max() ?? 0)
        let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width)

        let gauge = image(score: score, zone: zone, dark: dark)
        let height: CGFloat = 22
        let textX = gauge.size.width + 4
        let valueX = textX + labelWidth + 3
        let size = NSSize(width: valueX + valueWidth, height: height)

        // Lignes de base centrées sur la hauteur des capitales, pas sur la boîte du texte.
        let gap: CGFloat = 3.5
        let bottomBaseline = (height - 2 * valueFont.capHeight - gap) / 2
        let topBaseline = bottomBaseline + valueFont.capHeight + gap

        let rows: [(label: String, value: String, color: NSColor, baseline: CGFloat)] = [
            // Seul cas où l'on force une couleur : le rouge reste lisible dans les deux thèmes.
            ("RAM", "\(percent(score))%", zone == .critical ? .systemRed : ink, topBaseline),
            ("CPU", cpu.map { "\(percent($0))%" } ?? "–", ink, bottomBaseline),
        ]
        let alignRight = NSMutableParagraphStyle()
        alignRight.alignment = .right

        return NSImage(size: size, flipped: false) { _ in
            let gaugeY = (height - gauge.size.height) / 2
            gauge.draw(in: NSRect(origin: NSPoint(x: 0, y: gaugeY), size: gauge.size))

            for row in rows {
                // draw(at:) place le bas de la ligne (descendantes comprises) au point donné.
                (row.label as NSString).draw(
                    at: NSPoint(x: textX, y: row.baseline + labelFont.descender),
                    withAttributes: labelAttrs)
                let valueHeight = valueFont.ascender - valueFont.descender
                (row.value as NSString).draw(
                    in: NSRect(
                        x: valueX, y: row.baseline + valueFont.descender,
                        width: valueWidth, height: valueHeight),
                    withAttributes: [
                        .font: valueFont, .foregroundColor: row.color, .paragraphStyle: alignRight,
                    ])
            }
            return true
        }
    }

    /// Arrondi, borné à 0...100 : le même chiffre partout où il s'affiche ou se lit.
    static func percent(_ ratio: Double) -> Int {
        Int((max(0, min(1, ratio)) * 100).rounded())
    }
}
