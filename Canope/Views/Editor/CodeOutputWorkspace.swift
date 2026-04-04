import AppKit
import PDFKit
import SwiftUI
import WebKit

struct CodeOutputWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var documentState: CodeDocumentUIState
    let outputStatusLabel: String
    let revealArtifactDirectoryInFinder: () -> Void
    let refreshSelectedRun: () -> Void
    let persist: () -> Void

    @State private var secondaryDragStartFraction: CGFloat?
    @StateObject private var primaryZoomController = ImageArtifactZoomController()
    @StateObject private var secondaryZoomController = ImageArtifactZoomController()

    var body: some View {
        VStack(spacing: 0) {
            header

            if documentState.activeArtifacts.count > 1 {
                AppChromeDivider(role: .panel)
                artifactTabs
                    .frame(height: AppChromeMetrics.tabBarHeight)
                    .background(AppChromePalette.surfaceSubbar)
            }

            AppChromeDivider(role: .panel)

            workspaceContent
        }
        .frame(minWidth: 240, idealWidth: 380, maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Output", systemImage: "chart.xyaxis.line")
                .font(.caption)
                .fontWeight(.semibold)
            Text(outputStatusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if documentState.manualPreviewArtifact != nil {
                Button(action: {
                    documentState.returnToSelectedRun()
                    persist()
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Retourner au dernier run")
            } else {
                Button(action: {
                    documentState.selectPreviousRun()
                    persist()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(documentState.canSelectPreviousRun ? .secondary : .tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!documentState.canSelectPreviousRun)
                .help("Run précédent")

                Button(action: {
                    documentState.selectNextRun()
                    persist()
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(documentState.canSelectNextRun ? .secondary : .tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!documentState.canSelectNextRun)
                .help("Run suivant")

                Button(action: refreshSelectedRun) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(documentState.selectedRun == nil)
                .help("Actualiser le run sélectionné")
            }

            Button(action: {
                documentState.updateOutputLayout {
                    $0.secondaryPaneVisible.toggle()
                }
                persist()
            }) {
                Label("Comparer", systemImage: documentState.outputLayout.secondaryPaneVisible ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(documentState.outputLayout.secondaryPaneVisible ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .help("Afficher ou masquer le panneau de comparaison. Quand il est ouvert, clique un plot ou un PDF dans l’arborescence pour le charger dedans.")

            Button(action: {
                documentState.updateOutputLayout {
                    $0.secondaryPaneAxis = $0.secondaryPaneAxis == .vertical ? .horizontal : .vertical
                }
                persist()
            }) {
                Image(systemName: documentState.outputLayout.secondaryPaneAxis == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(documentState.outputLayout.secondaryPaneVisible ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!documentState.outputLayout.secondaryPaneVisible)
            .help("Changer l’orientation du split interne")

            Button(action: revealArtifactDirectoryInFinder) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Afficher le dossier d’artefacts")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppChromePalette.surfaceSubbar)
    }

    private var artifactTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(documentState.activeArtifacts) { artifact in
                    artifactTabButton(artifact)
                }
            }
        }
    }

    private var workspaceContent: some View {
        Group {
            if documentState.outputLayout.secondaryPaneVisible {
                secondarySplitContent
            } else {
                primaryPreviewPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var secondarySplitContent: some View {
        GeometryReader { proxy in
            let divider = LaTeXEditorThreePaneSizing.dividerWidth
            let fraction = CGFloat(documentState.outputLayout.secondaryPaneFraction)
            switch documentState.outputLayout.secondaryPaneAxis {
            case .vertical:
                let totalHeight = max(proxy.size.height - divider, 1)
                let minSecondary: CGFloat = 140
                let maxSecondary = max(minSecondary, totalHeight - 180)
                let seededSecondary = totalHeight * fraction
                let secondaryHeight = min(max(seededSecondary, minSecondary), maxSecondary)
                let primaryHeight = max(180, totalHeight - secondaryHeight)

                VStack(spacing: 0) {
                    primaryPreviewPane
                        .frame(height: primaryHeight)
                    AppChromeResizeHandle(
                        width: divider,
                        onHoverChanged: { hovering in
                            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                        },
                        dragGesture: AnyGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = secondaryDragStartFraction ?? fraction
                                    if secondaryDragStartFraction == nil {
                                        secondaryDragStartFraction = fraction
                                    }
                                    let next = start - (value.translation.height / max(totalHeight, 1))
                                    documentState.updateOutputLayout {
                                        $0.secondaryPaneFraction = Double(min(max(next, minSecondary / max(totalHeight, 1)), maxSecondary / max(totalHeight, 1)))
                                    }
                                }
                                .onEnded { _ in
                                    secondaryDragStartFraction = nil
                                    persist()
                                }
                        ),
                        axis: .horizontal
                    )
                    secondaryPreviewPane
                        .frame(height: secondaryHeight)
                }
            case .horizontal:
                let totalWidth = max(proxy.size.width - divider, 1)
                let minSecondary: CGFloat = 180
                let maxSecondary = max(minSecondary, totalWidth - 220)
                let seededSecondary = totalWidth * fraction
                let secondaryWidth = min(max(seededSecondary, minSecondary), maxSecondary)
                let primaryWidth = max(220, totalWidth - secondaryWidth)

                HStack(spacing: 0) {
                    primaryPreviewPane
                        .frame(width: primaryWidth)
                    AppChromeResizeHandle(
                        width: divider,
                        onHoverChanged: { hovering in
                            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        },
                        dragGesture: AnyGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = secondaryDragStartFraction ?? fraction
                                    if secondaryDragStartFraction == nil {
                                        secondaryDragStartFraction = fraction
                                    }
                                    let next = start - (value.translation.width / max(totalWidth, 1))
                                    documentState.updateOutputLayout {
                                        $0.secondaryPaneFraction = Double(min(max(next, minSecondary / max(totalWidth, 1)), maxSecondary / max(totalWidth, 1)))
                                    }
                                }
                                .onEnded { _ in
                                    secondaryDragStartFraction = nil
                                    persist()
                                }
                        ),
                        axis: .vertical
                    )
                    secondaryPreviewPane
                        .frame(width: secondaryWidth)
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var primaryPreviewPane: some View {
        ArtifactOutputPane(
            title: documentState.manualPreviewArtifact == nil ? "Aperçu principal" : "Aperçu manuel",
            artifact: documentState.activeArtifact,
            imageZoomController: primaryZoomController,
            accessory: nil
        )
    }

    private var secondaryPreviewPane: some View {
        let menuArtifacts = documentState.availableSecondaryArtifacts
        return ArtifactOutputPane(
            title: documentState.secondaryManualPreviewArtifact == nil ? "Comparaison" : "Comparaison manuelle",
            artifact: documentState.secondaryActiveArtifact,
            emptyDescription: nil,
            imageZoomController: secondaryZoomController,
            accessory: AnyView(
                HStack(spacing: 6) {
                    if !menuArtifacts.isEmpty {
                        Menu {
                            ForEach(menuArtifacts) { artifact in
                                Button {
                                    documentState.setSecondaryArtifactPath(artifact.url.path)
                                    persist()
                                } label: {
                                    HStack {
                                        if documentState.secondaryActiveArtifact?.url.path == artifact.url.path {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(artifact.displayName)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: {
                        documentState.clearSecondaryPreview()
                        persist()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            )
        )
    }

    private func artifactTabButton(_ artifact: ArtifactDescriptor) -> some View {
        let isSelected = artifact.url.path == documentState.activeArtifact?.url.path
        return Button {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                documentState.selectedArtifactPath = artifact.url.path
            }
            persist()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: artifact.kind))
                    .font(.system(size: 9))
                Text(artifact.displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AppChromePalette.tabFill(isSelected: isSelected, isHovered: false, role: .reference))
            .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconName(for artifactKind: ArtifactKind) -> String {
        switch artifactKind {
        case .pdf:
            return "doc.richtext"
        case .image:
            return "photo"
        case .html:
            return "globe"
        }
    }
}

private struct ArtifactOutputPane: View {
    let title: String
    let artifact: ArtifactDescriptor?
    var emptyDescription: String? = "Aucun artefact à afficher dans ce panneau."
    @ObservedObject var imageZoomController: ImageArtifactZoomController
    var accessory: AnyView?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                if let artifact {
                    Text(artifact.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let accessory {
                    accessory
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AppChromePalette.surfaceSubbar)

            AppChromeDivider(role: .panel)
            ArtifactPrimaryPreviewPane(
                artifact: artifact,
                emptyDescription: emptyDescription,
                imageZoomController: imageZoomController
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArtifactPrimaryPreviewPane: View {
    let artifact: ArtifactDescriptor?
    var emptyDescription: String? = "Aucun artefact à afficher dans ce panneau."
    @ObservedObject var imageZoomController: ImageArtifactZoomController

    var body: some View {
        Group {
            if let artifact {
                switch artifact.kind {
                case .pdf:
                    if let document = PDFDocument(url: artifact.url) {
                        PDFPreviewView(document: document, allowsInverseSync: false)
                    } else {
                        unavailableView(title: "PDF introuvable", systemImage: "doc.richtext", description: "Le PDF n’a pas pu être chargé.")
                    }
                case .image:
                    ZStack(alignment: .topTrailing) {
                        ZoomableImageArtifactView(url: artifact.url, controller: imageZoomController)
                        imageZoomControls
                            .padding(10)
                    }
                case .html:
                    WebArtifactView(url: artifact.url)
                }
            } else {
                unavailableView(title: "Aucune sortie", systemImage: "chart.xyaxis.line", description: emptyDescription)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imageZoomControls: some View {
        HStack(spacing: 4) {
            zoomButton(systemName: "arrow.up.left.and.down.right.magnifyingglass", help: "Ajuster", action: imageZoomController.fit)
            zoomButton(systemName: "1.magnifyingglass", help: "100 %", action: imageZoomController.actualSize)
            zoomButton(systemName: "minus.magnifyingglass", help: "Zoom arrière", action: imageZoomController.zoomOut)
            zoomButton(systemName: "plus.magnifyingglass", help: "Zoom avant", action: imageZoomController.zoomIn)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }

    private func zoomButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func unavailableView(title: String, systemImage: String, description: String?) -> some View {
        if let description, !description.isEmpty {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
        } else {
            Color.clear
        }
    }
}

@MainActor
final class ImageArtifactZoomController: ObservableObject {
    fileprivate enum Command {
        case fit
        case actualSize
        case zoomIn
        case zoomOut
    }

    @Published fileprivate var commandRevision: Int = 0
    fileprivate var pendingCommand: Command = .fit

    func fit() {
        pendingCommand = .fit
        commandRevision += 1
    }

    func actualSize() {
        pendingCommand = .actualSize
        commandRevision += 1
    }

    func zoomIn() {
        pendingCommand = .zoomIn
        commandRevision += 1
    }

    func zoomOut() {
        pendingCommand = .zoomOut
        commandRevision += 1
    }
}

private struct ZoomableImageArtifactView: NSViewRepresentable {
    let url: URL
    @ObservedObject var controller: ImageArtifactZoomController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = CenteredImageDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.addSubview(imageView)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 12.0
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        context.coordinator.attach(scrollView: scrollView, documentView: documentView, imageView: imageView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(url: url, commandRevision: controller.commandRevision)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private weak var documentView: CenteredImageDocumentView?
        private weak var imageView: NSImageView?
        private let controller: ImageArtifactZoomController
        private var lastURL: URL?
        private var lastCommandRevision: Int = -1

        init(controller: ImageArtifactZoomController) {
            self.controller = controller
        }

        func attach(scrollView: NSScrollView, documentView: CenteredImageDocumentView, imageView: NSImageView) {
            self.scrollView = scrollView
            self.documentView = documentView
            self.imageView = imageView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func update(url: URL, commandRevision: Int) {
            guard let scrollView, let imageView else { return }

            let didChangeImage = lastURL != url
            if didChangeImage {
                imageView.image = NSImage(contentsOf: url)
                imageView.frame = CGRect(origin: .zero, size: imageView.image?.size ?? .zero)
                lastURL = url
                fitImage()
            }

            guard lastCommandRevision != commandRevision else { return }
            lastCommandRevision = commandRevision
            switch controller.pendingCommand {
            case .fit:
                fitImage()
            case .actualSize:
                setMagnification(1.0)
            case .zoomIn:
                setMagnification(scrollView.magnification * 1.2)
            case .zoomOut:
                setMagnification(scrollView.magnification / 1.2)
            }
        }

        @objc
        func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            fitImage()
        }

        @objc
        private func contentViewBoundsDidChange(_ notification: Notification) {
            relayoutImage()
        }

        private func fitImage() {
            guard let scrollView,
                  let imageSize = imageView?.image?.size,
                  imageSize.width > 0,
                  imageSize.height > 0 else { return }
            let visibleSize = scrollView.contentSize
            let fit = min(visibleSize.width / imageSize.width, visibleSize.height / imageSize.height)
            setMagnification(fit)
        }

        private func setMagnification(_ value: CGFloat) {
            guard let scrollView, let imageView else { return }
            let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
            let center = CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
            scrollView.setMagnification(clamped, centeredAt: center)
            relayoutImage()
        }

        private func relayoutImage() {
            guard let scrollView,
                  let documentView,
                  let imageView,
                  let imageSize = imageView.image?.size,
                  imageSize.width > 0,
                  imageSize.height > 0 else { return }

            let effectiveVisibleSize = CGSize(
                width: scrollView.contentSize.width / max(scrollView.magnification, 0.001),
                height: scrollView.contentSize.height / max(scrollView.magnification, 0.001)
            )
            let documentSize = CGSize(
                width: max(imageSize.width, effectiveVisibleSize.width),
                height: max(imageSize.height, effectiveVisibleSize.height)
            )

            documentView.frame = CGRect(origin: .zero, size: documentSize)
            imageView.frame = CGRect(
                x: (documentSize.width - imageSize.width) / 2,
                y: (documentSize.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            documentView.needsLayout = true
        }
    }
}

private final class CenteredImageDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct WebArtifactView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let accessURL = url.deletingLastPathComponent()
        webView.loadFileURL(url, allowingReadAccessTo: accessURL)
    }
}
