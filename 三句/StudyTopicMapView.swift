import SwiftUI

struct StudyTopicMapView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.xxLarge) {
                header
                StudyTopicMapMosaic(cells: mapCells)
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, 88)
            .padding(.bottom, AppSpacing.xxxLarge)
        }
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: AppIconSize.prominent, weight: .bold))
                    .foregroundStyle(AppTextColor.primary)
                    .frame(width: 42, height: 42)
                    .background(AppSurfaceColor.input, in: Circle())
                    .overlay {
                        Circle().stroke(AppStroke.highlight, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .padding(.leading, AppSpacing.xLarge)
            .padding(.top, AppSpacing.medium)
            .accessibilityLabel(L10n.string("common.back", "返回"))
        }
        .task {
            await appModel.refreshUserStudySceneSummaries()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(L10n.string("study.topic.map.title", "我的语言地图"))
                .font(.system(size: AppFontSize.celebration, weight: .bold, design: .serif))
                .foregroundStyle(AppTextColor.primary)

            Text(
                L10n.string(
                    "study.topic.map.subtitle",
                    "%d 个主题，慢慢点亮",
                    mapCells.count
                )
            )
            .font(.system(size: AppFontSize.bodyProminent, weight: .medium))
            .foregroundStyle(AppTextColor.secondary)
        }
    }

    private var mapCells: [StudyTopicMapCell] {
        let scenesByLearningTopicID = Dictionary(grouping: appModel.userStudySceneSummaries) { scene in
            LearningTopic.topic(matchingName: scene.name)?.id
        }
        let matchedSceneIDs = Set(scenesByLearningTopicID.values.flatMap { $0.map(\.id) })

        let categorizedScenes = LearningTopic.all.compactMap { topic -> StudyTopicMapCell? in
            guard let scenes = scenesByLearningTopicID[topic.id], !scenes.isEmpty else {
                return nil
            }
            return StudyTopicMapCell(
                id: "topic:\(topic.id)",
                title: topic.title,
                summary: combinedSummary(for: scenes),
                isCreated: true
            )
        }

        let customScenes = appModel.userStudySceneSummaries
            .filter { !matchedSceneIDs.contains($0.id) }
            .map {
                StudyTopicMapCell(
                    id: "scene:\($0.id.uuidString.lowercased())",
                    title: $0.name,
                    summary: $0.summary,
                    isCreated: true
                )
            }

        let inactiveTopics = LearningTopic.all.compactMap { topic -> StudyTopicMapCell? in
            guard scenesByLearningTopicID[topic.id] == nil else { return nil }
            return StudyTopicMapCell(
                id: "topic:\(topic.id)",
                title: topic.title,
                summary: nil,
                isCreated: false
            )
        }

        return categorizedScenes + customScenes + inactiveTopics
    }

    private func combinedSummary(for scenes: [UserStudySceneSummary]) -> SentenceStudyTopicSummary {
        let totalCount = scenes.reduce(0) { $0 + $1.summary.totalCount }
        let weightedMasteryTotal = scenes.reduce(0) { partialResult, scene in
            partialResult + scene.summary.masteryScore * max(scene.summary.totalCount, 1)
        }
        let masteryWeight = scenes.reduce(0) { $0 + max($1.summary.totalCount, 1) }

        return SentenceStudyTopicSummary(
            totalCount: totalCount,
            dueCount: scenes.reduce(0) { $0 + $1.summary.dueCount },
            studiedCount: scenes.reduce(0) { $0 + $1.summary.studiedCount },
            reviewableTodayCount: scenes.reduce(0) { $0 + $1.summary.reviewableTodayCount },
            masteryScore: masteryWeight == 0 ? 0 : weightedMasteryTotal / masteryWeight
        )
    }
}

private struct StudyTopicMapCell: Identifiable {
    let id: String
    let title: String
    let summary: SentenceStudyTopicSummary?
    let isCreated: Bool
}

private struct StudyTopicMapMosaic: View {
    let cells: [StudyTopicMapCell]

    var body: some View {
        StudyTopicMapMosaicLayout(cells: cells) {
            ForEach(cells) { cell in
                StudyTopicMapCellView(cell: cell, seed: StudyTopicMapLayout.stableSeed(for: cell.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StudyTopicMapCellView: View {
    let cell: StudyTopicMapCell
    let seed: UInt64

    var body: some View {
        let shape = OrganicTopicMapShape(seed: seed)
        let tint = TopicMapPalette.color(for: cell.id)

        shape
            .fill(cell.isCreated ? tint.opacity(0.23) : AppSurfaceColor.elevated)
            .overlay {
                shape.stroke(
                    cell.isCreated ? tint.opacity(0.34) : AppStroke.highlight,
                    lineWidth: 1
                )
            }
            .overlay {
                VStack(spacing: AppSpacing.xSmall) {
                    Text(cell.title)
                        .font(.system(size: cell.isCreated ? AppFontSize.bodyProminent : AppFontSize.body, weight: .semibold))
                        .foregroundStyle(AppTextColor.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)

                    if let summary = cell.summary {
                        Text(
                            L10n.string(
                                "study.topic.map.mastery",
                                "掌握 %d%%",
                                summary.masteryScore
                            )
                        )
                        .font(.system(size: AppFontSize.metadata, weight: .medium))
                        .foregroundStyle(AppTextColor.secondary)
                    }
                }
                .padding(AppSpacing.medium)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let summary = cell.summary else { return cell.title }
        return "\(cell.title)，\(L10n.string("study.topic.map.mastery", "掌握 %d%%", summary.masteryScore))"
    }
}

private struct StudyTopicMapMosaicLayout: Layout {
    let cells: [StudyTopicMapCell]

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 360
        let placements = StudyTopicMapLayout.make(cells: cells, availableWidth: width)
        let height = (placements.map { $0.frame.maxY }.max() ?? 0) + StudyTopicMapLayout.bottomInset
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let placements = StudyTopicMapLayout.make(cells: cells, availableWidth: bounds.width)
        for (index, subview) in subviews.enumerated() where index < placements.count {
            let placement = placements[index]
            subview.place(
                at: CGPoint(x: bounds.minX + placement.frame.minX, y: bounds.minY + placement.frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: placement.frame.width, height: placement.frame.height)
            )
        }
    }
}

private enum StudyTopicMapLayout {
    private static let columns = 3
    private static let gap: CGFloat = 10
    static let bottomInset: CGFloat = AppSpacing.small

    static func make(cells: [StudyTopicMapCell], availableWidth: CGFloat) -> [Placement] {
        guard availableWidth > 0 else { return [] }

        let unitWidth = (availableWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
        var columnBottoms = Array(repeating: CGFloat.zero, count: columns)

        return cells.enumerated().map { index, cell in
            let seed = stableSeed(for: cell.id)
            let span = columnSpan(for: cell, seed: seed)
            let height = cellHeight(for: cell, unitWidth: unitWidth, seed: seed)
            let column = bestColumn(for: span, columnBottoms: columnBottoms)
            let y = columnBottoms[column..<(column + span)].max() ?? 0
            let width = unitWidth * CGFloat(span) + gap * CGFloat(span - 1)
            let frame = CGRect(
                x: CGFloat(column) * (unitWidth + gap),
                y: y,
                width: width,
                height: height
            )

            for occupiedColumn in column..<(column + span) {
                columnBottoms[occupiedColumn] = y + height + gap
            }

            return Placement(id: "\(cell.id)-\(index)", cell: cell, frame: frame, seed: seed)
        }
    }

    private static func columnSpan(for cell: StudyTopicMapCell, seed: UInt64) -> Int {
        if cell.title.count >= 7 { return 2 }
        if cell.isCreated && (cell.summary?.totalCount ?? 0) >= 10 { return 2 }
        return seededInt(seed, salt: 1, upperBound: 4) == 0 ? 2 : 1
    }

    private static func cellHeight(for cell: StudyTopicMapCell, unitWidth: CGFloat, seed: UInt64) -> CGFloat {
        let variance = CGFloat(seededInt(seed, salt: 2, upperBound: 23)) / 100
        let base = cell.isCreated ? 0.92 : 0.78
        return unitWidth * (base + variance)
    }

    private static func bestColumn(for span: Int, columnBottoms: [CGFloat]) -> Int {
        let candidates = 0...(columns - span)
        return candidates.min { lhs, rhs in
            let leftHeight = columnBottoms[lhs..<(lhs + span)].max() ?? 0
            let rightHeight = columnBottoms[rhs..<(rhs + span)].max() ?? 0
            return leftHeight < rightHeight
        } ?? 0
    }

    static func stableSeed(for value: String) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603) { partialResult, byte in
            (partialResult ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func seededInt(_ seed: UInt64, salt: UInt64, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        let mixed = seed &+ salt &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(mixed % UInt64(upperBound))
    }

    struct Placement: Identifiable {
        let id: String
        let cell: StudyTopicMapCell
        let frame: CGRect
        let seed: UInt64
    }
}

private struct OrganicTopicMapShape: Shape {
    let seed: UInt64

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: 1, dy: 1)
        let width = insetRect.width
        let height = insetRect.height
        let topInset = width * (0.14 + variation(1) * 0.08)
        let rightInset = height * (0.14 + variation(2) * 0.08)
        let bottomInset = width * (0.14 + variation(3) * 0.08)
        let leftInset = height * (0.14 + variation(4) * 0.08)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: insetRect.minX + width * x, y: insetRect.minY + height * y)
        }

        var path = Path()
        path.move(to: point(topInset / width, 0))
        path.addCurve(
            to: point(1 - topInset / width, 0),
            control1: point(0.36, variation(5) * 0.05),
            control2: point(0.66, variation(6) * 0.05)
        )
        path.addCurve(
            to: point(1, rightInset / height),
            control1: point(0.95, 0),
            control2: point(1, 0.06)
        )
        path.addCurve(
            to: point(1, 1 - rightInset / height),
            control1: point(1 - variation(7) * 0.04, 0.36),
            control2: point(1 - variation(8) * 0.04, 0.66)
        )
        path.addCurve(
            to: point(1 - bottomInset / width, 1),
            control1: point(1, 0.95),
            control2: point(0.94, 1)
        )
        path.addCurve(
            to: point(bottomInset / width, 1),
            control1: point(0.66, 1 - variation(9) * 0.05),
            control2: point(0.36, 1 - variation(10) * 0.05)
        )
        path.addCurve(
            to: point(0, 1 - leftInset / height),
            control1: point(0.05, 1),
            control2: point(0, 0.94)
        )
        path.addCurve(
            to: point(0, leftInset / height),
            control1: point(variation(11) * 0.04, 0.66),
            control2: point(variation(12) * 0.04, 0.36)
        )
        path.addCurve(
            to: point(topInset / width, 0),
            control1: point(0, 0.05),
            control2: point(0.06, 0)
        )
        path.closeSubpath()
        return path
    }

    private func variation(_ salt: UInt64) -> CGFloat {
        let mixed = seed &+ salt &* 2_862_933_555_777_941_757
        return CGFloat(mixed % 10_000) / 10_000
    }
}

private enum TopicMapPalette {
    private static let colors: [Color] = [
        Color(red: 0.45, green: 0.62, blue: 0.48),
        Color(red: 0.92, green: 0.53, blue: 0.32),
        Color(red: 0.36, green: 0.62, blue: 0.84),
        Color(red: 0.93, green: 0.68, blue: 0.24),
        Color(red: 0.58, green: 0.48, blue: 0.78)
    ]

    static func color(for id: String) -> Color {
        let seed = id.utf8.reduce(0) { $0 + Int($1) }
        return colors[seed % colors.count]
    }
}
