# Contributing to Canope

## Prerequisites

- macOS 14+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

Optional for full feature parity:

- [MacTeX](https://tug.org/mactex/) (LaTeX compile / preview)
- [Claude Code](https://code.claude.com/) CLI (`claude` on your `PATH`) for AI and IDE-bridge workflows from the integrated terminal

## Generate the Xcode project

The gitignored `Canope.xcodeproj` is produced from [`project.yml`](project.yml):

```bash
xcodegen generate
open Canope.xcodeproj
```

## Build and test from the CLI

```bash
xcodegen generate
xcodebuild -project Canope.xcodeproj -scheme Canope -destination 'platform=macOS' build
xcodebuild -project Canope.xcodeproj -scheme Canope -destination 'platform=macOS' test
```

CI runs the same test command on pull requests (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## Branches and changes

- Prefer focused commits and pull requests tied to a single concern (feature, fix, or doc).
- Match existing Swift style: clarity over cleverness, and avoid unrelated refactors in the same change as a bugfix.
