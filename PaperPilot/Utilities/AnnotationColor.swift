import AppKit
import SwiftUI

struct AnnotationColor {
    // Default colors
    static let yellow = NSColor(red: 1.0, green: 0.95, blue: 0.0, alpha: 1.0)
    static let green = NSColor(red: 0.0, green: 0.85, blue: 0.3, alpha: 1.0)
    static let red = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
    static let blue = NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0)
    static let purple = NSColor(red: 0.7, green: 0.3, blue: 0.9, alpha: 1.0)

    static let defaults: [NSColor] = [yellow, green, red, blue, purple]

    /// Named color list for context menus (uses current favorites)
    static var all: [(name: String, color: NSColor)] {
        let favorites = loadFavorites()
        return favorites.enumerated().map { (index, color) in
            ("Couleur \(index + 1)", color)
        }
    }

    private static let userDefaultsKey = "favoriteAnnotationColors"

    /// Load the user's 5 favorite colors from UserDefaults, or return defaults.
    static func loadFavorites() -> [NSColor] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let colors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSColor.self, from: data),
              colors.count == 5 else {
            return defaults
        }
        return colors
    }

    /// Save 5 favorite colors to UserDefaults.
    static func saveFavorites(_ colors: [NSColor]) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: colors, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// Replace one favorite color at a given index.
    static func replaceFavorite(at index: Int, with color: NSColor) {
        var favorites = loadFavorites()
        guard index >= 0, index < favorites.count else { return }
        favorites[index] = color
        saveFavorites(favorites)
    }
}
