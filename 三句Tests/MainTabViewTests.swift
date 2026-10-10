import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class MainTabViewTests: XCTestCase {
    func testNativeTabBarShowsAllTabsAndReservesBottomSafeArea() async throws {
        let model = try makeModel()
        defer { model.speech.stop() }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let host = try TabViewHost(model: model, style: style)
            defer { host.close() }
            for (index, tab) in [AppTab.newLearning, .memories, .favorites, .profile].enumerated() {
                model.selectedTab = tab
                try await host.settle()
                let controller = try XCTUnwrap(host.tabController)
                XCTAssertEqual(controller.tabBar.items?.count, 4)
                XCTAssertEqual(controller.selectedIndex, index)
                XCTAssertFalse(controller.tabBar.isHidden)
                XCTAssertGreaterThan(try XCTUnwrap(controller.selectedViewController).view.safeAreaInsets.bottom,
                                     host.window.safeAreaInsets.bottom)
                attach(host.snapshot(), name: "NativeTabs-\(tab)-\(style.rawValue)")
            }
        }
    }

    func testNativeTabBarHidesInMemoryDetailsAndReturnsAtRoot() async throws {
        let model = try makeModel()
        model.selectedTab = .memories
        let host = try TabViewHost(model: model)
        defer { host.close(); model.speech.stop() }
        try await host.settle()
        let controller = try XCTUnwrap(host.tabController)
        XCTAssertFalse(controller.tabBar.isHidden)
        for route in [MemoryNavigationRoute.photoTopic("restaurants_and_cafes"), .memory(model.memories[0].id)] {
            model.memoriesNavigationPath = [route]
            try await host.settle()
            XCTAssertTrue(controller.tabBar.isHidden)
            attach(host.snapshot(), name: "NativeTabs-MemoryDetail-\(route)")
            model.memoriesNavigationPath = []
            try await host.settle()
            XCTAssertFalse(controller.tabBar.isHidden)
        }
    }

    func testFavoritesOpensDirectlyWithTheNativeTabBar() async throws {
        let model = try makeModel()
        model.selectedTab = .favorites
        let host = try TabViewHost(model: model)
        defer { host.close(); model.speech.stop() }
        try await host.settle()
        let controller = try XCTUnwrap(host.tabController)
        XCTAssertFalse(controller.tabBar.isHidden)
        XCTAssertEqual(controller.tabBar.items?[2].title, L10n.string("tab.favorites", "收藏"))
        func navigationController(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.lazy.compactMap { navigationController(in: $0) }.first
        }
        let navigation = try XCTUnwrap(navigationController(in: try XCTUnwrap(controller.selectedViewController)))
        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertTrue(navigation.navigationBar.prefersLargeTitles)
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, L10n.string("tab.favorites", "收藏"))
        XCTAssertEqual(model.sentenceStudyDueCount, 1)
        XCTAssertEqual(FavoriteSentenceListItem.makeItems(memories: model.memories, studyCounts: [:]).count, 1)
        attach(host.snapshot(), name: "NativeTabs-FavoritesRoot")
    }

    func testFavoritesBadgeLoadsWithoutOpeningFavoritesAndTracksDueCount() async throws {
        let model = try makeModel()
        model.selectedTab = .newLearning
        model.studyOverviewLoadState = .idle
        model.sentenceStudyDueCount = 0
        let host = try TabViewHost(model: model)
        defer { host.close(); model.speech.stop() }
        try await host.settle()
        let controller = try XCTUnwrap(host.tabController)
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(model.sentenceStudyDueCount, 1)
        XCTAssertEqual(controller.tabBar.items?[2].badgeValue, "1")
        for count in [3, 12, 0, -1] {
            model.sentenceStudyDueCount = count
            try await host.settle()
            XCTAssertEqual(controller.tabBar.items?[2].badgeValue, count > 0 ? String(count) : nil)
        }
        model.sentenceStudyDueCount = 12
        try await host.settle()
        attach(host.snapshot(), name: "NativeTabs-FavoritesBadge")
    }

    func testSwitchingTabsStillResetsProfileNavigation() async throws {
        let model = try makeModel()
        model.selectedTab = .profile
        let host = try TabViewHost(model: model)
        defer { host.close(); model.speech.stop() }
        try await host.settle()
        model.profileNavigationPath = [.aboutUs]
        try await host.settle()
        XCTAssertFalse(try XCTUnwrap(host.tabController).tabBar.isHidden)
        model.selectedTab = .newLearning
        try await host.settle()
        XCTAssertTrue(model.profileNavigationPath.isEmpty)
        model.selectedTab = .profile
        try await host.settle()
        XCTAssertFalse(try XCTUnwrap(host.tabController).tabBar.isHidden)
    }

    private func makeModel() throws -> AppModel {
        let model = AppModel()
        let photo = try XCTUnwrap(UIImage(named: "OnboardingCafe")?.jpegData(compressionQuality: 0.8))
        model.memories = [MemoryEntry(imageData: photo, tags: ["restaurants_and_cafes"], sentences: [
            SentenceRecord(english: "The coffee smells really good.", chinese: "咖啡闻起来很香。", isFavorite: true)
        ])]
        model.memoryLoadState = .loaded
        return model
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class TabViewHost {
    let window: UIWindow
    private let controller: UIHostingController<AnyView>
    private let previousKeyWindow: UIWindow?

    init(model: AppModel, style: UIUserInterfaceStyle = .light) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = style
        controller = UIHostingController(rootView: AnyView(MainTabView().environmentObject(model)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    var tabController: UITabBarController? { findTabController(in: controller) }

    func settle() async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
    }

    func snapshot() -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    private func findTabController(in controller: UIViewController) -> UITabBarController? {
        if let tabController = controller as? UITabBarController { return tabController }
        return controller.children.lazy.compactMap { self.findTabController(in: $0) }.first
    }
}
