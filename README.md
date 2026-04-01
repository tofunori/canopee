# Canope 🌳

A native macOS scientific paper reader, annotator, LaTeX editor, and AI assistant — all in one app.

*Papers come from trees — Canope keeps them organized.*

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
- **Drag & drop import** — drop PDFs onto the table or use the + button

### PDF Reader & Annotations
- **Tabbed interface** — open multiple papers in tabs within one window
- **Split view** — compare two papers side by side
- **Highlight** with live color preview during selection
- **Underline & Strikethrough** — text markup annotations
- **Sticky notes** — click to place, double-click to edit
- **Text boxes** (FreeText) — drag to draw rectangle, type text inline with formatting options (font size, color, alignment)
- **Shapes** — rectangle, oval with custom Metal-compatible rendering
- **Arrows** — line annotations with arrowheads
- **Freehand drawing** — ink annotations
- **Annotation sidebar** — list all annotations grouped by page
- **Right-click context menu** — change color, font size, text alignment, delete
- **Resize annotations** — drag corner handles
- **Undo** (Cmd+Z) — undo last annotation
- **Auto-save** — annotations saved to PDF after every change
- **5 customizable color slots** — right-click to change, persisted across sessions

### LaTeX Editor
- **Integrated editor** — open .tex files in a new tab alongside your PDFs
- **Syntax highlighting** — commands (blue), math (green), comments (gray), environments (purple), braces (orange)
- **5 editor themes** — Kaku Dark, Monokai, Dracula, Nord, Solarized
- **Adjustable font size** — 11pt to 24pt via toolbar menu
- **Live PDF preview** — compiled output displayed alongside the editor
- **Flexible layouts** — side-by-side, top/bottom, or editor-only
- **Compilation** — compile via latexmk/pdflatex with Cmd+B or auto-compile on save
- **Error panel** — compilation errors with line numbers, click to navigate
- **File browser** — project directory tree (.tex, .bib, .pdf, images)
- **File watching** — auto-reload when files are modified externally (e.g., by Claude Code)
- **Selection sync** — selected text in the editor is visible to Claude Code

### Integrated Terminal (GPU-Accelerated)
- **SwiftTerm + Metal** — GPU-accelerated terminal rendering
- **Multi-tab terminals** — open multiple independent shell sessions
- **Horizontal split** — run two terminals side by side (e.g., Claude Code + Codex)
- **8 terminal themes** — Kaku Dark, Dracula, Monokai, Nord, Tokyo Night, Gruvbox, Solarized, Light
- **Adjustable font size** — 12pt to 24pt
- **Persistent sessions** — terminal stays alive when switching tabs
- **Mouse scroll support** — scroll works in TUI apps (neovim, less, htop) via SGR mouse reporting
- **Option key support** — Option+key produces macOS special characters

### Claude Code Integration
- **PDF context** — full paper text written to `/tmp/canope_paper.txt` (auto-updates on tab switch)
- **IDE bridge** — selected text from the PDF reader or LaTeX editor is sent to Claude Code through the built-in IDE MCP bridge
- **Terminal wrapper** — `claude` launched from the integrated terminal automatically uses the Canope IDE bridge
- **CLAUDE.md instructions** — Claude Code automatically reads paper context and IDE-backed selections
- **Bi-directional workflow** — edit LaTeX in Claude Code terminal, changes auto-reload in the editor

### Keyboard Shortcuts
| Key | Action |
|-----|--------|
| `1`-`9` | Select annotation tool |
| `Esc` | Return to pointer |
| `Cmd+Z` | Undo last annotation |
| `Cmd+S` | Save (PDF or LaTeX) |
| `Cmd+B` | Compile LaTeX |
| `Cmd+I` | Toggle inspector panel |
| `Cmd+Shift+T` | Toggle terminal |
| `Cmd+O` | Open .tex file |
| `Delete` | Delete selected annotation |

## Tech Stack

- **SwiftUI** — native macOS UI framework
- **PDFKit** — Apple's PDF rendering and annotation engine
- **SwiftData** — modern data persistence (replaces Core Data)
- **SwiftTerm** — terminal emulator with Metal GPU rendering
- **CrossRef API** — automatic metadata lookup by DOI
- **latexmk / pdflatex** — LaTeX compilation (requires MacTeX)

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+
- Apple Silicon or Intel Mac
- [MacTeX](https://tug.org/mactex/) (for LaTeX compilation)

## Building

```bash
# Install xcodegen if needed
brew install xcodegen

# Clone and build
git clone https://github.com/tofunori/canopee.git
cd canopee
xcodegen generate

# Build from command line
xcodebuild -project Canope.xcodeproj -scheme Canope -destination 'platform=macOS' build

# Or open in Xcode
open Canope.xcodeproj
# Then Cmd+R to build and run
```

## Releases

### Build a DMG locally

```bash
./scripts/build-release-dmg.sh
```

That creates a distributable DMG in `build/release/`.

### Publish a GitHub release

The repo now includes a workflow at `.github/workflows/release-dmg.yml`.

- Push a tag like `v0.1.0`, or run the workflow manually from GitHub.
- The workflow builds `Canope.app`, packages it as a `.dmg`, uploads it as an artifact, and attaches it to a GitHub Release.

Example:

```bash
git tag v0.1.0
git push origin v0.1.0
```

### Important macOS distribution note

The workflow can publish a DMG immediately, but a smooth macOS install experience needs Apple signing and notarization.

- Without Apple Developer signing/notarization, users can still download the app, but macOS Gatekeeper will warn them.
- To ship a cleaner public release, add these GitHub repository secrets:
  - `APPLE_DEVELOPER_CERTIFICATE_P12`
  - `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`
  - `APPLE_DEVELOPER_IDENTITY`
  - `APPLE_TEAM_ID`
  - `APPLE_ID`
  - `APPLE_APP_SPECIFIC_PASSWORD`

When those secrets are present, the release workflow will sign the app, notarize the DMG, and staple the notarization ticket automatically.

## Architecture

```
Canope/
├── CanopeApp.swift                  # App entry point, process cleanup
├── ContentView.swift                # Main window: tabs, split view, terminal
├── Models/
│   ├── Paper.swift                  # SwiftData model (title, authors, DOI, rating, labels...)
│   └── PaperCollection.swift       # Hierarchical collection model
├── Views/
│   ├── Library/
│   │   ├── PaperTableView.swift        # Papers-style sortable table
│   │   └── PaperInfoPanel.swift        # Inspector panel for metadata
│   ├── Sidebar/
│   │   └── SidebarView.swift           # Collection tree view with sub-collections
│   ├── PDFReader/
│   │   ├── PDFReaderView.swift         # Reader container with annotation toolbar
│   │   ├── PDFKitView.swift            # NSViewRepresentable PDFView + overlay system
│   │   ├── AnnotationToolbar.swift     # Tool & color selection bar
│   │   ├── AnnotationSidebarView.swift # Annotation list by page
│   │   └── AIChatPanel.swift           # Terminal panel (SwiftTerm + Metal)
│   ├── Editor/
│   │   ├── LaTeXEditorView.swift       # LaTeX editor main view
│   │   ├── LaTeXTextEditor.swift       # NSTextView with syntax highlighting
│   │   ├── FileBrowserView.swift       # Project file tree browser
│   │   └── CompilationErrorView.swift  # Error/warning list panel
│   └── Common/
│       └── RatingView.swift            # 5-star rating widget
├── Services/
│   ├── AnnotationService.swift         # PDF annotation creation (markup, shapes, arrows)
│   ├── MetadataExtractor.swift         # DOI extraction + CrossRef API lookup
│   ├── PDFFileManager.swift            # PDF import and storage
│   ├── ClaudeService.swift             # Claude CLI integration
│   └── LaTeXCompiler.swift             # latexmk/pdflatex compilation + error parsing
└── Utilities/
    ├── AnnotationTool.swift            # Tool enum (pointer, highlight, shapes, arrow...)
    ├── AnnotationColor.swift           # Color palette with UserDefaults persistence
    └── ShapeAnnotations.swift          # Custom PDFAnnotation subclasses (rect, oval, arrow)
```

## Claude Code Integration

Canope writes context files that Claude Code reads automatically:

| File | Content | Updated when |
|------|---------|-------------|
| `/tmp/canope_paper.txt` | Full text of the currently open paper | Tab switch |
| `/tmp/canope_ide_selection.json` | Current editor or PDF selection exposed through the IDE bridge | Selection changes |
| `/tmp/canope_claude_ide_mcp.json` | Claude Code MCP config for the built-in Canope IDE bridge | App launch |

Add this to your `~/.claude/CLAUDE.md` for automatic integration:

```markdown
## Canope
- `/tmp/canope_paper.txt` — currently open paper (read when user asks about "the paper")
- Selections from Canope now come from the IDE integration context
- Do NOT use pdf-selection skill (reads from Skim, not Canope)
```

## License

MIT
