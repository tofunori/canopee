# Canopée 🌳

A native macOS scientific paper reader and library manager built with SwiftUI and PDFKit.

*Papers come from trees — Canopée keeps them organized.*

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Library Management
- **Papers-style table view** with sortable columns (authors, title, journal, year, rating)
- **Hierarchical collections** with sub-collections (Zotero-style tree view)
- **Smart collections** — All Papers, Favorites, Unread, Recent
- **Color labels & shapes** — tag papers with colored icons (circle, star, diamond, heart...)
- **5-star rating system** — rate papers directly in the table
- **Full-text search** across titles, authors, DOI, and journal
- **Inspector panel** — view and edit metadata inline (Cmd+I)
- **Auto metadata extraction** — DOI detection + CrossRef API lookup for title, authors, year, journal

### PDF Reader & Annotations
- **Tabbed interface** — open multiple papers in tabs within one window
- **Split view** — compare two papers side by side
- **Highlight** with live color preview during selection (yellow, green, red, blue, purple + custom colors)
- **Underline & Strikethrough** — text markup annotations
- **Sticky notes** — click to place, double-click to edit
- **Text boxes** (FreeText) — drag to draw rectangle, type text inline
- **Shapes** — rectangle, oval with custom `draw(with:in:)` rendering
- **Arrows** — line annotations with arrowheads
- **Freehand drawing** — ink annotations
- **Annotation sidebar** — list all annotations grouped by page
- **Right-click context menu** — change color, font size, text alignment, delete
- **Resize annotations** — drag corner handles
- **Undo** (Cmd+Z) — undo last annotation
- **Auto-save** — annotations saved to PDF after every change
- **5 customizable color slots** — right-click to change, persisted across sessions

### Keyboard Shortcuts
| Key | Action |
|-----|--------|
| `1`-`9` | Select annotation tool |
| `Esc` | Return to pointer |
| `Cmd+Z` | Undo last annotation |
| `Cmd+S` | Save PDF |
| `Cmd+I` | Toggle inspector panel |
| `Delete` | Delete selected annotation |

## Tech Stack

- **SwiftUI** — native macOS UI framework
- **PDFKit** — Apple's PDF rendering and annotation engine
- **SwiftData** — modern data persistence (replaces Core Data)
- **CrossRef API** — automatic metadata lookup by DOI
- **Zero dependencies** — no Electron, no web views, pure native Swift

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+
- Apple Silicon or Intel Mac

## Building

```bash
# Install xcodegen if needed
brew install xcodegen

# Generate Xcode project
cd Canopee
xcodegen generate

# Build
xcodebuild -project Canopée.xcodeproj -scheme PaperPilot -destination 'platform=macOS' build

# Or open in Xcode
open Canopée.xcodeproj
```

## Architecture

```
PaperPilot/
├── PaperPilotApp.swift          # App entry point, window configuration
├── ContentView.swift            # Main window with tabs, split view, library
├── Models/
│   ├── Paper.swift              # SwiftData model (title, authors, DOI, rating...)
│   └── PaperCollection.swift   # Hierarchical collection model
├── Views/
│   ├── Library/
│   │   ├── PaperTableView.swift    # Papers-style sortable table
│   │   └── PaperInfoPanel.swift    # Inspector panel for metadata
│   ├── Sidebar/
│   │   └── SidebarView.swift       # Collection tree view
│   ├── PDFReader/
│   │   ├── PDFReaderView.swift     # Reader container with toolbar
│   │   ├── PDFKitView.swift        # NSViewRepresentable PDFView wrapper
│   │   ├── AnnotationToolbar.swift # Tool & color selection
│   │   └── AnnotationSidebarView.swift # Annotation list
│   └── Common/
│       └── RatingView.swift        # 5-star rating widget
├── Services/
│   ├── AnnotationService.swift     # PDF annotation creation
│   ├── MetadataExtractor.swift     # DOI extraction + CrossRef lookup
│   └── PDFFileManager.swift        # PDF import and storage
└── Utilities/
    ├── AnnotationTool.swift        # Tool enum
    ├── AnnotationColor.swift       # Color palette with UserDefaults persistence
    └── ShapeAnnotations.swift      # Custom PDFAnnotation subclasses for shapes
```

## License

MIT
