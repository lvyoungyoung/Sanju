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
                FavoritesView()
            }
            .tag(AppTab.favorites)
            .tabItem {
                Label(L10n.string("tab.favorites", "收藏"), systemImage: "heart")
            }
            .badge(favoritesTabBadgeValue)

            NavigationStack {
                ProfileView()
            }
            .tag(AppTab.profile)
            .tabItem {
                Label(L10n.string("tab.profile", "我的"), systemImage: "person.circle")
            }
        }
        .tint(.orange)
    }

    private var favoritesTabBadgeValue: String? {
        guard appModel.sentenceStudyDueCount > 0 else {
            return nil
        }
        return appModel.sentenceStudyDueCount > 99 ? "99+" : "\(appModel.sentenceStudyDueCount)"
    }
}
