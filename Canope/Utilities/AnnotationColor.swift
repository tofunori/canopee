import AppKit
import SwiftUI
import PDFKit

struct AnnotationColor {
    // Softer default colors for highlights and markup.
    static let yellow = NSColor(red: 0.97, green: 0.89, blue: 0.38, alpha: 1.0)
    static let green = NSColor(red: 0.34, green: 0.79, blue: 0.50, alpha: 1.0)
    static let red = NSColor(red: 0.95, green: 0.53, blue: 0.50, alpha: 1.0)
    static let blue = NSColor(red: 0.47, green: 0.63, blue: 0.96, alpha: 1.0)
    static let purple = NSColor(red: 0.74, green: 0.52, blue: 0.88, alpha: 1.0)

    static let defaults: [NSColor] = [yellow, green, red, blue, purple]

    private static let legacyDefaults: [NSColor] = [
        NSColor(red: 1.0, green: 0.95, blue: 0.0, alpha: 1.0),
        NSColor(red: 0.0, green: 0.85, blue: 0.3, alpha: 1.0),
        NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0),
        NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0),
        NSColor(red: 0.7, green: 0.3, blue: 0.9, alpha: 1.0),
    ]

    /// Named color list for context menus (uses current favorites)
    static var all: [(name: String, color: NSColor)] {
        let favorites = loadFavorites()
        return favorites.enumerated().map { (index, color) in
            ("Couleur \(index + 1)", color)
        }
    }

    private static let userDefaultsKey = "favoriteAnnotationColors"
    private static let defaultHighlightPreviewOpacity: CGFloat = 0.4
    private static let defaultLiveHighlightOpacity: CGFloat = 0.32
    private static let defaultTextBoxFillOpacity: CGFloat = 0.15
    private static let defaultMarkupPreviewOpacity: CGFloat = 0.6

    /// Load the user's 5 favorite colors from UserDefaults, or return defaults.
    static func loadFavorites() -> [NSColor] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let colors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSColor.self, from: data),
              colors.count == 5 else {
            return defaults
        }
        let normalizedColors = colors.map(normalized)

        // Migrate older installs that still persist the original, more saturated defaults.
        if paletteMatches(normalizedColors, legacyDefaults) {
            saveFavorites(defaults)
            return defaults
        }

        return normalizedColors
    }

    /// Save 5 favorite colors to UserDefaults.
    static func saveFavorites(_ colors: [NSColor]) {
        let normalizedColors = colors.map(normalized)
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: normalizedColors, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// Replace one favorite color at a given index.
    static func replaceFavorite(at index: Int, with color: NSColor) {
        var favorites = loadFavorites()
        guard index >= 0, index < favorites.count else { return }
        favorites[index] = color
        saveFavorites(favorites)
    }

    static func normalized(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? color
    }

    static func annotationColor(_ color: NSColor, for type: PDFAnnotationSubtype) -> NSColor {
        switch type {
        case .highlight:
            // Let PDFKit render the final highlight appearance without forcing
            // an extra alpha here; this keeps the live view closer to the
            // serialized/reopened appearance.
            return normalized(color)
        default:
            return normalized(color)
        }
    }

    static func annotationColor(_ color: NSColor, for annotationType: String) -> NSColor {
        switch annotationType {
        case "Highlight":
            return normalized(color)
        case "FreeText":
            return blendedOpaqueColor(color, intensity: defaultTextBoxFillOpacity)
        default:
            return normalized(color)
        }
    }

    static func annotationColor(_ color: NSColor, for annotationType: String?) -> NSColor {
        annotationColor(color, for: annotationType ?? "")
    }

    static func previewColor(_ color: NSColor, for tool: AnnotationTool) -> NSColor {
        switch tool {
        case .highlight:
            return applyingDefaultOpacityIfNeeded(color, alpha: defaultHighlightPreviewOpacity)
        case .underline, .strikethrough:
            return applyingDefaultOpacityIfNeeded(color, alpha: defaultMarkupPreviewOpacity)
        default:
            return normalized(color)
        }
    }

    static func liveHighlightColor(_ color: NSColor) -> NSColor {
        applyingDefaultOpacityIfNeeded(color, alpha: defaultLiveHighlightOpacity)
    }

    static func storedTextBoxFillColor(_ color: NSColor?) -> NSColor {
        guard let color else {
            return blendedOpaqueColor(yellow, intensity: defaultTextBoxFillOpacity)
        }

        let normalizedColor = normalized(color)
        if normalizedColor.alphaComponent < 0.999 {
            return blendedOpaqueColor(normalizedColor, intensity: defaultTextBoxFillOpacity)
        }

        let baseCandidates = loadFavorites() + legacyDefaults
        if baseCandidates.contains(where: { colorsApproximatelyEqual(normalizedColor, $0) }) {
            return blendedOpaqueColor(normalizedColor, intensity: defaultTextBoxFillOpacity)
        }

        let blendedCandidates = baseCandidates.map {
            blendedOpaqueColor($0, intensity: defaultTextBoxFillOpacity)
        }
        if blendedCandidates.contains(where: { colorsApproximatelyEqual(normalizedColor, $0) }) {
            return normalizedColor
        }

        return normalizedColor
    }

    private static func applyingDefaultOpacityIfNeeded(_ color: NSColor, alpha: CGFloat) -> NSColor {
        let normalizedColor = normalized(color)
        if abs(normalizedColor.alphaComponent - 1.0) < 0.001 {
            return normalizedColor.withAlphaComponent(alpha)
        }
        return normalizedColor
    }

    private static func blendedOpaqueColor(_ color: NSColor, intensity: CGFloat, background: NSColor = .white) -> NSColor {
        let normalizedColor = normalized(color)
        let normalizedBackground = normalized(background)
        let clampedIntensity = max(0.0, min(1.0, intensity))
        let backgroundWeight = 1.0 - clampedIntensity

        return NSColor(
            red: normalizedBackground.redComponent * backgroundWeight + normalizedColor.redComponent * clampedIntensity,
            green: normalizedBackground.greenComponent * backgroundWeight + normalizedColor.greenComponent * clampedIntensity,
            blue: normalizedBackground.blueComponent * backgroundWeight + normalizedColor.blueComponent * clampedIntensity,
            alpha: 1.0
        )
    }

    private static func colorsApproximatelyEqual(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.01) -> Bool {
        let lhs = normalized(lhs)
        let rhs = normalized(rhs)

        return abs(lhs.redComponent - rhs.redComponent) <= tolerance &&
               abs(lhs.greenComponent - rhs.greenComponent) <= tolerance &&
               abs(lhs.blueComponent - rhs.blueComponent) <= tolerance &&
               abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    private static func paletteMatches(_ lhs: [NSColor], _ rhs: [NSColor], tolerance: CGFloat = 0.01) -> Bool {
        guard lhs.count == rhs.count else { return false }

        for (left, right) in zip(lhs.map(normalized), rhs.map(normalized)) {
            guard abs(left.redComponent - right.redComponent) <= tolerance,
                  abs(left.greenComponent - right.greenComponent) <= tolerance,
                  abs(left.blueComponent - right.blueComponent) <= tolerance,
                  abs(left.alphaComponent - right.alphaComponent) <= tolerance else {
                return false
            }
        }

        return true
    }
}
