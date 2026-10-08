import SwiftUI
import UIKit

// Both generation preferences share native styling and per-segment disabling.
struct PreferenceSegmentedControl: UIViewRepresentable {
    let titles: [String]
    @Binding var selection: Int
    let accessibilityTitle: String
    var disabledIndices: Set<Int> = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 44)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = makeControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func makeControl() -> UISegmentedControl {
        let control = UISegmentedControl(items: titles)
        control.apportionsSegmentWidthsByContent = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.backgroundColor = UIColor(AppSurfaceColor.subtleFill)
        control.selectedSegmentTintColor = UIColor(AppSurfaceColor.card)
        control.setTitleTextAttributes([.foregroundColor: UIColor(AppPalette.accentText)], for: .selected)
        control.setTitleTextAttributes([.foregroundColor: UIColor.tertiaryLabel], for: .disabled)
        update(control)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        update(control)
    }

    func update(_ control: UISegmentedControl) {
        control.accessibilityLabel = accessibilityTitle
        if control.numberOfSegments != titles.count {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() {
                control.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
        for (index, title) in titles.enumerated() {
            control.setTitle(title, forSegmentAt: index)
            control.setEnabled(!disabledIndices.contains(index), forSegmentAt: index)
        }
        control.selectedSegmentIndex = titles.indices.contains(selection) ? selection : UISegmentedControl.noSegment
    }

    final class Coordinator: NSObject {
        var parent: PreferenceSegmentedControl

        init(_ parent: PreferenceSegmentedControl) { self.parent = parent }

        @objc func changed(_ control: UISegmentedControl) {
            let index = control.selectedSegmentIndex
            if parent.titles.indices.contains(index), !parent.disabledIndices.contains(index) {
                parent.selection = index
            }
            // A binding can reject an update when preference changes are rate limited.
            parent.update(control)
        }
    }
}
