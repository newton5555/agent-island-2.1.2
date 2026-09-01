import CoreGraphics
import Foundation

/// Manual magnifier for the island on screens WITHOUT a notch — external
/// monitors, where the "4K text is tiny" reports come from (large scaled
/// or native-resolution modes shrink a point well below MacBook size).
/// Notched MacBooks are exempt: the silhouette must keep matching the
/// physical housing, so it always renders 1:1 there.
@MainActor
final class InterfaceScaleStore: ObservableObject {
    static let shared = InterfaceScaleStore()

    private static let key = "AgentIsland.interfaceScale"

    /// Offered steps; 1.0 is the default.
    static let steps: [CGFloat] = [1.0, 1.15, 1.3, 1.5]

    @Published var factor: CGFloat {
        didSet { UserDefaults.standard.set(Double(factor), forKey: Self.key) }
    }

    private init() {
        let saved = CGFloat(UserDefaults.standard.double(forKey: Self.key))
        self.factor = Self.steps.contains(saved) ? saved : 1.0
    }
}
