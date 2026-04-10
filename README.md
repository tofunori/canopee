# Canope

Canope is a native macOS workspace for reading scientific papers, annotating PDFs, editing LaTeX, and working with local AI tools in the same window.

It is designed for research workflows where the paper, the writing environment, and the assistant need to stay connected.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## What Canope Does

### Read and organize papers
- Library view with sortable metadata, collections, ratings, and search
- Fast PDF import with metadata extraction from DOI / CrossRef when available
- Multi-tab reading workflow inside a single desktop window
- Side-by-side comparison for papers and reader workspaces

### Annotate PDFs directly
- Text highlights, underlines, strike-through, notes, free text, shapes, arrows, and freehand drawing
- Inline editing, resizing, context menus, and annotation sidebar
- Auto-save back into the PDF after annotation changes

### Write in LaTeX with live preview
- Native macOS editor workflow for `.tex` projects
- Project file browser and compilation panel
- Compiled PDF preview in the same workspace
- File watching so external edits can flow back into the app

### Work with local AI in context
- Native chat tabs for both Claude and Codex
- IDE-context bridge from the PDF reader and editor selections
- Integrated terminal workflows for local tools
- Per-chat configuration such as model, reasoning level, IDE context, and plan mode

## Core Workflows

### Library and PDF workspace
Canope keeps the paper library, reader, annotations, and metadata editing in one native macOS interface. The goal is to reduce context switching between a reference manager, a PDF reader, and the writing workspace.

### Editor workspace
The editor side is built for paper-adjacent writing rather than as a generic IDE. LaTeX files can be edited, compiled, previewed, and revisited without leaving the same application state.

### AI-assisted research workflow
Canope can expose the active paper text and the current selection to local AI tools. This makes it easier to ask questions about the current document, refine notes, or work on adjacent writing tasks without manually copying context around.

## AI and Terminal Integration

Canope currently exposes two native chat providers in-app:
- Claude
- Codex

It also prepares local terminal wrappers so integrated terminal sessions can inherit Canope context when available.

Context files written by Canope:

| File | Purpose |
|------|---------|
| `/tmp/canope_paper.txt` | Text snapshot of the currently open paper |
| `/tmp/canope_ide_selection.json` | Current selection from the editor or PDF view |
| `/tmp/canope_claude_ide_mcp.json` | MCP bridge config used by the Canope IDE bridge |

These files are useful for local assistant workflows and terminal-driven tooling.

## Requirements

### Required
- macOS 14 or later
- Xcode 16 or later
- Apple Silicon or Intel Mac
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Optional

| Feature | Requirement |
|--------|-------------|
| LaTeX compile and preview | A TeX distribution that provides `latexmk` or `pdflatex` on `PATH` |
| DOI metadata lookup | Network access for CrossRef requests |
| Claude terminal workflow | `claude` CLI available on `PATH` |
| Codex terminal workflow | `codex` CLI available on `PATH` |
| Signed / notarized public distribution | Apple Developer signing and notarization credentials |

## Quick Start

### Build the app

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Canope.xcodeproj -scheme Canope -destination 'platform=macOS' build
```

### Run with the local dev script

The repo includes a shell-first run script that rebuilds and launches the app using a fixed derived data path:

```bash
./script/build_and_run.sh
```

Useful variants:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

### Run tests

```bash
xcodebuild \
  -project Canope.xcodeproj \
  -scheme Canope \
  -destination 'platform=macOS' \
  test \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contributor setup.

## Releases

### Build a DMG locally

```bash
./scripts/build-release-dmg.sh
```

This creates a DMG in `build/release/`.

If you want the file name to include a version suffix:

```bash
VERSION_SUFFIX=0.4.1 ./scripts/build-release-dmg.sh
```

### Publish a GitHub release

The repository includes [`release-dmg.yml`](.github/workflows/release-dmg.yml), which builds `Canope.app`, packages it as a DMG, uploads the artifact, and attaches it to a GitHub release.

Typical flow:

1. Bump the app version in [`project.yml`](project.yml).
2. Regenerate the project with `xcodegen generate`.
3. Commit the version bump.
4. Push a tag like `v0.4.1`.

Example:

```bash
git tag v0.4.1
git push origin v0.4.1
```

### Unsigned vs signed distribution

| Situation | What users should expect |
|-----------|--------------------------|
| Local / ad-hoc signed DMG | Gatekeeper may warn on first launch |
| Developer ID signed and notarized DMG | Smoother public installation experience |

For signed and notarized releases, configure these repository secrets:
- `APPLE_DEVELOPER_CERTIFICATE_P12`
- `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_IDENTITY`
- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

## Repository Layout

High-level source layout:

```text
Canope/
├── Models/        SwiftData models and shared domain types
├── Services/      AI providers, compilation, metadata, workspace state, bridge services
├── Utilities/     Low-level helpers and annotation utilities
├── Views/
│   ├── Chat/      Native Claude / Codex chat UI
│   ├── Editor/    LaTeX and editor-side workspace
│   ├── Library/   Library shell and metadata flows
│   ├── PDFReader/ Reader, annotations, integrated terminal / chat panel
│   ├── PaperList/ Paper table and rows
│   ├── Reader/    Reader-specific supporting views
│   ├── Shared/    Reusable chrome, tabs, and layout helpers
│   ├── Sidebar/   Sidebar navigation
│   └── Common/    Shared view helpers used across modules
├── CanopeApp.swift
└── MainWindow.swift
```

Project generation and packaging helpers:

```text
project.yml
script/build_and_run.sh
scripts/build-release-dmg.sh
scripts/notarize-dmg.sh
.github/workflows/ci.yml
.github/workflows/release-dmg.yml
```

## Development Notes

- `Canope.xcodeproj` is generated from [`project.yml`](project.yml).
- The local run script uses `build/CodexDerivedData` for predictable rebuilds.
- The release script uses `build/release/DerivedData` and produces a distributable DMG.
- The app can run without LaTeX tooling or AI CLIs, but those features stay unavailable until the required tools are installed.

## License

MIT
