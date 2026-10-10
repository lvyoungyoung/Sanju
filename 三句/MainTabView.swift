import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        tabContent
            .background(AppSurfaceColor.page)
            .tint(AppPalette.accentText)
            .task {
                await appModel.ensureRemoteSessionRestoreCompleted()
                if appModel.studyOverviewLoadState == .idle {
                    await appModel.refreshSentenceStudyDueCount()
                }
            }
            .onChange(of: appModel.selectedTab) { _, selectedTab in
                if selectedTab != .profile {
                    appModel.profileNavigationPath = []
                }
            }
    }

    private var tabContent: some View {
        TabView(selection: $appModel.selectedTab) {
            NavigationStack {
                NewLearningView()
            }
            .toolbar(.visible, for: .tabBar)
            .tag(AppTab.newLearning)
            .tabItem {
                Label(L10n.string("tab.new", "新的"), systemImage: "plus")
            }

            NavigationStack(path: $appModel.memoriesNavigationPath) {
                MemoriesView()
                    .navigationDestination(for: MemoryNavigationRoute.self) { route in
                        switch route {
                        case .memory(let memoryID):
                            MemoryDetailView(memoryID: memoryID)
                        case .photoTopic(let topicID):
                            MemoriesView(topicID: topicID)
                        }
                    }
            }
            .tag(AppTab.memories)
            .toolbar(appModel.memoriesNavigationPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem {
                Label(L10n.string("tab.memories", "回忆"), systemImage: "photo.on.rectangle")
            }

            NavigationStack {
                FavoritesView()
            }
            .tag(AppTab.favorites)
            .toolbar(.visible, for: .tabBar)
            .tabItem {
                Label(L10n.string("tab.favorites", "收藏"), systemImage: "star")
            }
            .badge(max(0, appModel.sentenceStudyDueCount))

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
            .toolbar(.visible, for: .tabBar)
            .tabItem {
                Label(L10n.string("tab.profile", "我的"), systemImage: "person")
            }
        }
    }
}
