import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Reserve actual layout space: TabView does not reliably propagate an outer safeAreaInset.
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsTabBar {
                tabBar
            }
        }
        .background(AppSurfaceColor.page)
        .tint(AppPalette.accentText)
        .onChange(of: appModel.selectedTab) { _, selectedTab in
            if selectedTab != .profile {
                appModel.profileNavigationPath = []
            }
            if selectedTab != .study {
                appModel.studyNavigationPath = []
            }
        }
    }

    private var tabContent: some View {
        TabView(selection: $appModel.selectedTab) {
            NavigationStack {
                NewLearningView()
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(AppTab.newLearning)
            .tabItem {
                Label(L10n.string("tab.new", "新的"), systemImage: "sparkles.rectangle.stack")
            }

            NavigationStack(path: $appModel.memoriesNavigationPath) {
                MemoriesView()
                    .navigationDestination(for: UUID.self) { memoryID in
                        MemoryDetailView(memoryID: memoryID)
                    }
            }
            .tag(AppTab.memories)
            .toolbar(.hidden, for: .tabBar)
            .tabItem {
                Label(L10n.string("tab.memories", "回忆"), systemImage: "photo.on.rectangle")
            }

            NavigationStack(path: $appModel.studyNavigationPath) {
                StudyView()
                    .navigationDestination(for: StudySceneDetailRoute.self) { route in
                        StudySceneDetailView(route: route)
                    }
            }
            .tag(AppTab.study)
            .toolbar(.hidden, for: .tabBar)
            .tabItem {
                Label(L10n.string("tab.study", "学习"), systemImage: "book.closed")
            }

            NavigationStack(path: $appModel.profileNavigationPath) {
                ProfileView()
                    .navigationDestination(for: ProfileNavigationRoute.self) { route in
                        switch route {
                        case .aboutUs:
                            AboutUsView()
                        case .speechSettings:
                            SpeechSettingsView(speech: appModel.speech)
                        }
                    }
            }
            .tag(AppTab.profile)
            .toolbar(.hidden, for: .tabBar)
            .tabItem {
                Label(L10n.string("tab.profile", "我的"), systemImage: "person.circle")
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tab(.newLearning, title: L10n.string("tab.new", "新的"), icon: "plus")
            tab(.memories, title: L10n.string("tab.memories", "回忆"), icon: "photo.on.rectangle")
            tab(.study, title: L10n.string("tab.study", "学习"), icon: "book.closed")
            tab(.profile, title: L10n.string("tab.profile", "我的"), icon: "person")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppSurfaceColor.page)
        .overlay(alignment: .top) {
            Rectangle().fill(AppStroke.subtle).frame(height: 0.5)
        }
    }

    private var showsTabBar: Bool {
        switch appModel.selectedTab {
        case .memories: return appModel.memoriesNavigationPath.isEmpty
        case .study: return appModel.studyNavigationPath.isEmpty
        default: return true
        }
    }

    private func tab(_ tab: AppTab, title: String, icon: String) -> some View {
        let isSelected = appModel.selectedTab == tab
        return Button {
            appModel.selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 21, weight: .regular))
                Text(title).font(.system(.caption2, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? AppPalette.accentText : AppTextColor.secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isSelected ? AppPalette.apricot : .clear, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
