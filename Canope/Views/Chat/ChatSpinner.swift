import SwiftUI

// MARK: - Blinking Cursor Modifier

extension View {
    func blinking(duration: Double = 0.6) -> some View {
        modifier(BlinkingModifier(duration: duration))
    }
}

struct BlinkingModifier: ViewModifier {
    let duration: Double
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever()) {
                    isVisible = false
                }
            }
    }
}

// MARK: - Thinking Dots Animation

private let spinnerVerbs = [
    "Thinking", "Noodling", "Pondering", "Musing", "Mulling",
    "Ruminating", "Cogitating", "Contemplating", "Orchestrating",
    "Percolating", "Brewing", "Simmering", "Cooking", "Marinating",
    "Fermenting", "Incubating", "Hatching", "Crafting", "Tinkering",
    "Meandering", "Vibing", "Clauding", "Synthesizing", "Harmonizing",
    "Concocting", "Crystallizing", "Churning", "Forging",
    "Crunching", "Gallivanting", "Spelunking", "Perambulating",
    "Lollygagging", "Shenaniganing", "Whatchamacalliting",
    "Combobulating", "Discombobulating", "Recombobulating",
    "Flibbertigibbeting", "Razzmatazzing", "Tomfoolering",
    "Boondoggling", "Canoodling", "Befuddling", "Doodling",
    "Moonwalking", "Philosophising", "Puttering", "Puzzling",
]

struct SpinnerVerbView: View {
    @State private var verb = spinnerVerbs.randomElement() ?? "Thinking"
    @State private var timer: Timer?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 2)

            HStack(spacing: 6) {
                ThinkingDots()
                Text("\(verb)…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.top, 5)

            Spacer()
        }
        .padding(.vertical, 4)
        .transition(.opacity)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    verb = spinnerVerbs.randomElement() ?? "Thinking"
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct ThinkingDots: View {
    @State private var active = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .opacity(active == i ? 1.0 : 0.25)
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    active = (active + 1) % 3
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
