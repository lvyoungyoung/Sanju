import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView(selection: $appModel.selectedTab) {
            NavigationStack {
                NewLearningView()
            }
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
            .tabItem {
                Label(L10n.string("tab.memories", "回忆"), systemImage: "photo.on.rectangle")
            }

            NavigationStack {
                StudyView()
            }
            .tag(AppTab.study)
            .tabItem {
                Label(L10n.string("tab.study", "学习"), systemImage: "book.closed")
            }

            NavigationStack(path: $appModel.profileNavigationPath) {
                ProfileView()
                    .navigationDestination(for: ProfileNavigationRoute.self) { route in
                        switch route {
                        case .aboutUs:
                            AboutUsView()
                        }
                    }
            }
            .tag(AppTab.profile)
            .tabItem {
                Label(L10n.string("tab.profile", "我的"), systemImage: "person.circle")
            }
        }
        .tint(.orange)
        .onChange(of: appModel.selectedTab) { _, selectedTab in
            guard selectedTab != .profile else { return }
            appModel.profileNavigationPath = []
        }
    }

}
