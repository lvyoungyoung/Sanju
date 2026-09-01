import SwiftUI

struct StudyTopicMapView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.xxLarge) {
                header
                StudyTopicMapMosaic(cells: mapCells)
                    .environmentObject(appModel)
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
        let createdTopicIDs = Set(
            appModel.userStudySceneSummaries.compactMap {
                LearningTopic.topic(matchingName: $0.name)?.id
            }
        )

        let createdScenes = appModel.userStudySceneSummaries.map { scene in
            let learningTopic = LearningTopic.topic(matchingName: scene.name)
            return StudyTopicMapCell(
                id: "scene:\(scene.id.uuidString.lowercased())",
                title: learningTopic?.title ?? scene.name,
                summary: scene.summary,
                route: .userScene(scene)
            )
        }

        let inactiveTopics = LearningTopic.all.compactMap { topic -> StudyTopicMapCell? in
            guard !createdTopicIDs.contains(topic.id) else { return nil }
            return StudyTopicMapCell(
                id: "topic:\(topic.id)",
                title: topic.title,
                summary: nil,
                route: nil
            )
        }

        return createdScenes + inactiveTopics
    }
}

private struct StudyTopicMapCell: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: SentenceStudyTopicSummary?
    let route: StudySceneDetailRoute?

    var isCreated: Bool { summary != nil }
}

private struct StudyTopicMapMosaic: View {
    @EnvironmentObject private var appModel: AppModel
    let cells: [StudyTopicMapCell]

    private var mapHeight: CGFloat {
        StudyTopicPowerDiagram.mapHeight(for: cells.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let regions = StudyTopicPowerDiagram.make(cells: cells, size: proxy.size)

            ZStack(alignment: .topLeading) {
                ForEach(regions) { region in
                    StudyTopicMapRegionView(region: region)
                        .environmentObject(appModel)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(height: mapHeight)
        .frame(maxWidth: .infinity)
    }
}

private struct StudyTopicMapRegionView: View {
    @EnvironmentObject private var appModel: AppModel
    let region: StudyTopicMapRegion

    var body: some View {
        let shape = RoundedPowerPolygonShape(points: region.points)
        let tint = TopicMapPalette.color(for: region.cell.id)

        ZStack {
            shape
                .fill(region.cell.isCreated ? tint.opacity(0.24) : AppSurfaceColor.elevated)

            shape
                .stroke(
                    region.cell.isCreated ? tint.opacity(0.36) : AppStroke.highlight,
                    lineWidth: 1
                )

            VStack(spacing: AppSpacing.xSmall) {
                Text(region.cell.title)
                    .font(.system(size: region.cell.isCreated ? AppFontSize.bodyProminent : AppFontSize.body, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                if let summary = region.cell.summary {
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
            .frame(width: region.labelWidth)
            .position(region.labelPoint)
        }
        .contentShape(shape)
        .onTapGesture {
            guard let route = region.cell.route else { return }
            appModel.studyNavigationPath.append(route)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(region.cell.route == nil ? [] : .isButton)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let summary = region.cell.summary else { return region.cell.title }
        return "\(region.cell.title)，\(L10n.string("study.topic.map.mastery", "掌握 %d%%", summary.masteryScore))"
    }
}

private enum StudyTopicPowerDiagram {
    private static let groupGap: CGFloat = 14
    private static let regionInset: CGFloat = 2

    static func mapHeight(for itemCount: Int) -> CGFloat {
        max(1_240, CGFloat(itemCount) * 52)
    }

    static func make(cells: [StudyTopicMapCell], size: CGSize) -> [StudyTopicMapRegion] {
        guard size.width > 0, size.height > 0 else { return [] }

        let activeCells = cells.filter(\.isCreated)
        let inactiveCells = cells.filter { !$0.isCreated }

        guard !activeCells.isEmpty else {
            return makeGroup(cells: inactiveCells, in: CGRect(origin: .zero, size: size))
        }
        guard !inactiveCells.isEmpty else {
            return makeGroup(cells: activeCells, in: CGRect(origin: .zero, size: size))
        }

        let activeFraction = min(
            0.58,
            max(0.30, CGFloat(activeCells.count) / CGFloat(cells.count) * 1.45)
        )
        let activeHeight = size.height * activeFraction - groupGap / 2
        let activeBounds = CGRect(x: 0, y: 0, width: size.width, height: activeHeight)
        let inactiveBounds = CGRect(
            x: 0,
            y: activeHeight + groupGap,
            width: size.width,
            height: size.height - activeHeight - groupGap
        )

        return makeGroup(cells: activeCells, in: activeBounds) +
            makeGroup(cells: inactiveCells, in: inactiveBounds)
    }

    private static func makeGroup(cells: [StudyTopicMapCell], in bounds: CGRect) -> [StudyTopicMapRegion] {
        guard !cells.isEmpty else { return [] }

        let boundary = bounds.insetBy(dx: regionInset, dy: regionInset)
        let sites = initialSites(for: cells, in: boundary)
        var powers = Array(repeating: CGFloat.zero, count: cells.count)
        let desiredAreas = desiredAreas(for: cells, totalArea: boundary.width * boundary.height)

        for _ in 0..<12 {
            let polygons = polygons(for: sites, powers: powers, boundary: boundary)
            for index in powers.indices {
                let areaError = desiredAreas[index] - polygonArea(polygons[index])
                let maximumPower = max(boundary.width * boundary.width, boundary.height * boundary.height)
                powers[index] = min(
                    max(powers[index] + areaError * 0.32, -maximumPower),
                    maximumPower
                )
            }
        }

        let finalPolygons = polygons(for: sites, powers: powers, boundary: boundary)
        return zip(cells.indices, cells).compactMap { index, cell in
            let polygon = finalPolygons[index]
            guard polygon.count >= 3, polygonArea(polygon) > 1 else { return nil }
            let labelPoint = polygonCentroid(polygon)
            let labelWidth = max(76, min(170, polygonBounds(polygon).width - AppSpacing.large))
            return StudyTopicMapRegion(
                id: cell.id,
                cell: cell,
                points: inset(polygon, toward: labelPoint, amount: 0.93),
                labelPoint: labelPoint,
                labelWidth: labelWidth
            )
        }
    }

    private static func desiredAreas(for cells: [StudyTopicMapCell], totalArea: CGFloat) -> [CGFloat] {
        let weights = cells.map { cell -> CGFloat in
            guard let summary = cell.summary else {
                return 1 + normalizedSeed(for: cell.id, salt: 2) * 0.24
            }
            let sentenceWeight = min(0.78, sqrt(CGFloat(max(summary.totalCount, 0))) * 0.18)
            return 1.25 + sentenceWeight
        }
        let totalWeight = weights.reduce(0, +)
        return weights.map { $0 / totalWeight * totalArea }
    }

    private static func initialSites(for cells: [StudyTopicMapCell], in bounds: CGRect) -> [CGPoint] {
        let count = cells.count
        let columns = max(1, Int(ceil(sqrt(Double(count) * Double(bounds.width / bounds.height)))))
        let rows = Int(ceil(Double(count) / Double(columns)))

        return cells.enumerated().map { index, cell in
            let column = index % columns
            let row = index / columns
            let xJitter = (normalizedSeed(for: cell.id, salt: 4) - 0.5) * 0.34
            let yJitter = (normalizedSeed(for: cell.id, salt: 5) - 0.5) * 0.34
            let x = (CGFloat(column) + 0.5 + xJitter) / CGFloat(columns)
            let y = (CGFloat(row) + 0.5 + yJitter) / CGFloat(rows)
            return CGPoint(
                x: bounds.minX + min(max(x, 0.08), 0.92) * bounds.width,
                y: bounds.minY + min(max(y, 0.08), 0.92) * bounds.height
            )
        }
    }

    private static func polygons(for sites: [CGPoint], powers: [CGFloat], boundary: CGRect) -> [[CGPoint]] {
        sites.indices.map { index in
            var polygon = rectanglePoints(for: boundary)

            for otherIndex in sites.indices where otherIndex != index {
                let site = sites[index]
                let otherSite = sites[otherIndex]
                let normal = CGPoint(x: otherSite.x - site.x, y: otherSite.y - site.y)
                let constant = (
                    otherSite.x * otherSite.x + otherSite.y * otherSite.y - powers[otherIndex] -
                    site.x * site.x - site.y * site.y + powers[index]
                ) / 2
                polygon = clipped(polygon, normal: normal, constant: constant)
                guard polygon.count >= 3 else { return [] }
            }

            return polygon
        }
    }

    private static func clipped(_ polygon: [CGPoint], normal: CGPoint, constant: CGFloat) -> [CGPoint] {
        guard !polygon.isEmpty else { return [] }

        var result: [CGPoint] = []
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let startValue = dot(start, normal) - constant
            let endValue = dot(end, normal) - constant
            let startInside = startValue <= 0.0001
            let endInside = endValue <= 0.0001

            if startInside {
                result.append(start)
            }

            if startInside != endInside {
                let denominator = startValue - endValue
                guard abs(denominator) > 0.000_001 else { continue }
                let ratio = startValue / denominator
                result.append(
                    CGPoint(
                        x: start.x + (end.x - start.x) * ratio,
                        y: start.y + (end.y - start.y) * ratio
                    )
                )
            }
        }
        return result
    }

    private static func rectanglePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        let signedArea = points.indices.reduce(CGFloat.zero) { partialResult, index in
            let next = points[(index + 1) % points.count]
            return partialResult + points[index].x * next.y - next.x * points[index].y
        }
        return abs(signedArea) / 2
    }

    private static func polygonCentroid(_ points: [CGPoint]) -> CGPoint {
        guard points.count >= 3 else {
            let averageX = points.map(\.x).reduce(0, +) / CGFloat(max(points.count, 1))
            let averageY = points.map(\.y).reduce(0, +) / CGFloat(max(points.count, 1))
            return CGPoint(x: averageX, y: averageY)
        }

        var signedArea: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            let cross = point.x * next.y - next.x * point.y
            signedArea += cross
            x += (point.x + next.x) * cross
            y += (point.y + next.y) * cross
        }

        guard abs(signedArea) > 0.000_001 else {
            let averageX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
            let averageY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
            return CGPoint(x: averageX, y: averageY)
        }
        return CGPoint(x: x / (3 * signedArea), y: y / (3 * signedArea))
    }

    private static func polygonBounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    private static func inset(_ points: [CGPoint], toward center: CGPoint, amount: CGFloat) -> [CGPoint] {
        points.map {
            CGPoint(
                x: center.x + ($0.x - center.x) * amount,
                y: center.y + ($0.y - center.y) * amount
            )
        }
    }

    private static func dot(_ point: CGPoint, _ normal: CGPoint) -> CGFloat {
        point.x * normal.x + point.y * normal.y
    }

    private static func normalizedSeed(for value: String, salt: UInt64) -> CGFloat {
        let seed = value.utf8.reduce(1_469_598_103_934_665_603) { partialResult, byte in
            (partialResult ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let mixed = seed &+ salt &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(mixed % 10_000) / 10_000
    }
}

private struct StudyTopicMapRegion: Identifiable {
    let id: String
    let cell: StudyTopicMapCell
    let points: [CGPoint]
    let labelPoint: CGPoint
    let labelWidth: CGFloat
}

private struct RoundedPowerPolygonShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        guard points.count >= 3 else { return Path() }

        let roundedPoints = points.indices.map { index -> (before: CGPoint, vertex: CGPoint, after: CGPoint) in
            let previous = points[(index - 1 + points.count) % points.count]
            let vertex = points[index]
            let next = points[(index + 1) % points.count]
            let radius = min(28, min(distance(previous, vertex), distance(vertex, next)) * 0.24)
            return (
                point(from: vertex, toward: previous, distance: radius),
                vertex,
                point(from: vertex, toward: next, distance: radius)
            )
        }

        var path = Path()
        path.move(to: roundedPoints[0].after)
        for index in roundedPoints.indices {
            let nextIndex = (index + 1) % roundedPoints.count
            path.addLine(to: roundedPoints[nextIndex].before)
            path.addQuadCurve(to: roundedPoints[nextIndex].after, control: roundedPoints[nextIndex].vertex)
        }
        path.closeSubpath()
        return path
    }

    private func point(from source: CGPoint, toward target: CGPoint, distance: CGFloat) -> CGPoint {
        let length = self.distance(source, target)
        guard length > 0.000_001 else { return source }
        return CGPoint(
            x: source.x + (target.x - source.x) / length * distance,
            y: source.y + (target.y - source.y) / length * distance
        )
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
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
