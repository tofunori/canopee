import AppKit
import PDFKit

@MainActor
final class PDFSearchController {
    weak var pdfView: PDFView?
    var searchState: PDFSearchUIState?
    var onClearTextSelectionState: (() -> Void)?
    var onResetProgrammaticSelectionState: (() -> Void)?

    private var searchMatches: [PDFSelection] = []
    private var lastSearchQuery = ""
    private(set) var isUpdatingSearchSelection = false

    init(searchState: PDFSearchUIState? = nil) {
        self.searchState = searchState
    }

    func configureSearchState() {
        searchState?.configureActions(
            next: { [weak self] in
                self?.navigateSearch(step: 1)
            },
            previous: { [weak self] in
                self?.navigateSearch(step: -1)
            },
            clear: { [weak self] in
                self?.clearSearchResults()
            }
        )
    }

    func resetSearchQueryCache() {
        lastSearchQuery = ""
    }

    func syncSearchQuery(force: Bool) {
        let query = searchState?.query ?? ""
        guard force || query != lastSearchQuery else { return }
        lastSearchQuery = query
        updateSearchResults(for: query)
    }

    func clearSearchResults() {
        searchMatches = []
        searchState?.matchCount = 0
        searchState?.currentMatchIndex = 0
        onClearTextSelectionState?()
    }

    private func updateSearchResults(for query: String) {
        guard let pdfView else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            clearSearchResults()
            return
        }

        searchMatches = pdfView.document?.findString(trimmedQuery, withOptions: [.caseInsensitive]) ?? []
        searchState?.matchCount = searchMatches.count

        guard searchMatches.isEmpty == false else {
            searchState?.currentMatchIndex = 0
            onClearTextSelectionState?()
            return
        }

        showSearchMatch(at: 0)
    }

    private func navigateSearch(step: Int) {
        guard searchMatches.isEmpty == false else { return }
        let currentIndex = max(searchState?.currentMatchIndex ?? 1, 1) - 1
        let nextIndex = (currentIndex + step + searchMatches.count) % searchMatches.count
        showSearchMatch(at: nextIndex)
    }

    private func showSearchMatch(at index: Int) {
        guard let pdfView,
              searchMatches.indices.contains(index) else { return }

        let selection = searchMatches[index]
        onResetProgrammaticSelectionState?()
        isUpdatingSearchSelection = true
        pdfView.setCurrentSelection(selection, animate: true)
        if let page = selection.pages.first {
            let bounds = selection.bounds(for: page).insetBy(dx: -24, dy: -24)
            if bounds.isNull == false, bounds.isEmpty == false {
                pdfView.go(to: bounds, on: page)
            }
        }
        isUpdatingSearchSelection = false
        searchState?.currentMatchIndex = index + 1
    }
}
