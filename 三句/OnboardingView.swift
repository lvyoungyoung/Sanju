import SwiftUI

@MainActor
enum OnboardingProgress {
    static let completedKey = "sanju.onboarding.completed"
    static let startedKey = "sanju.onboarding.started"

    static func beginIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: completedKey) else { return false }
        // An interrupted introduction must survive the install marker being set by AppModel.
        guard defaults.bool(forKey: startedKey) || !defaults.bool(forKey: AppStorageKey.installMarker) else {
            return false
        }
        defaults.set(true, forKey: startedKey)
        return true
    }

    static func complete(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
        defaults.removeObject(forKey: startedKey)
    }
}

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case photo, expression, practice
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .photo: L10n.string("onboarding.photo.title", "每张照片都有触动你的地方，它可以是一处风景，一种味道，一种感觉。")
        case .expression: L10n.string("onboarding.expression.title", "用英语来描述照片里触动你的地方。")
        case .practice: L10n.string("onboarding.practice.title", "把“这句真好”，\n练成“这句我会”。")
        }
    }

    var subtitle: String {
        switch self {
        case .photo: L10n.string("onboarding.photo.body", "你拍下的生活，就是最值得学习的内容。")
        case .expression: L10n.string("onboarding.expression.body", "收藏最触动你的那一句，让你的感觉帮助你记忆。")
        case .practice: L10n.string("onboarding.practice.body", "围绕熟悉的画面反复练习，让想说的话，慢慢变成自己的表达。")
        }
    }

    var artworkDescription: String {
        switch self {
        case .photo: L10n.string("onboarding.photo.artwork", "翻看相册，选中并展开一张阳光下的咖啡馆照片。")
        case .expression: L10n.string("onboarding.expression.artwork", "同一张照片有三种表达，选中并收藏了 I could sit here all afternoon and do nothing. 我可以在这里坐一下午，什么也不做。")
        case .practice: L10n.string("onboarding.practice.artwork", "填空演示：从 I could sit here all afternoon and do nothing. 中挖去 sit、afternoon 和 nothing，再依次选词补全。")
        }
    }
}

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: OnboardingPage = .photo
    let onFinish: () -> Void

    init(initialPage: OnboardingPage = .photo, onFinish: @escaping () -> Void) {
        _page = State(initialValue: initialPage)
        self.onFinish = onFinish
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.string("onboarding.brand", "三句"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(AppTextColor.title)
                    Spacer()
                    Button(L10n.string("onboarding.skip", "跳过"), action: onFinish)
                        .font(.subheadline)
                        .foregroundStyle(AppTextColor.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(OnboardingPage.allCases) { item in
                        ScrollView(showsIndicators: false) {
                            OnboardingPageContent(
                                page: item,
                                artworkHeight: item == .practice
                                    ? min(340, max(250, geometry.size.height * 0.43))
                                    : min(300, max(200, geometry.size.height * 0.34)),
                                isActive: item == page
                            )
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                                .padding(.bottom, 20)
                        }
                        .tag(item)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 14) {
                    HStack(spacing: 0) {
                        ForEach(OnboardingPage.allCases) { item in
                            Button {
                                select(item)
                            } label: {
                                Capsule()
                                    .fill(item == page ? AppPalette.accent : AppTextColor.tertiary.opacity(0.3))
                                    .frame(width: item == page ? 24 : 7, height: 7)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.string("onboarding.page", "第 %d 页，共 3 页", item.rawValue + 1))
                            .accessibilityAddTraits(item == page ? .isSelected : [])
                        }
                    }
                    Button {
                        if let next = OnboardingPage(rawValue: page.rawValue + 1) {
                            select(next)
                        } else {
                            onFinish()
                        }
                    } label: {
                        HStack {
                            Text(page == .practice
                                 ? L10n.string("onboarding.start", "从我的照片开始")
                                 : L10n.string("onboarding.next", "下一页"))
                            Spacer()
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppPalette.onAccent)
                        .padding(.horizontal, 22)
                        .frame(minHeight: AppControlHeight.prominent)
                        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    }
                    .buttonStyle(StudioPressStyle())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .background(AppSurfaceColor.page.ignoresSafeArea())
    }

    private func select(_ next: OnboardingPage) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page = next }
    }
}

struct OnboardingPageContent: View {
    let page: OnboardingPage
    let artworkHeight: CGFloat
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var practicePhase: OnboardingPracticePhase = .completeSentence
    @State private var albumPhase: OnboardingAlbumPhase = .album
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 30.0
    @ScaledMetric(relativeTo: .title2) private var storyTitleSize = 24.0

    private var shouldAnimateAlbum: Bool {
        page == .photo && isActive && !reduceMotion && scenePhase == .active
    }

    private var shouldAnimatePractice: Bool {
        page == .practice && isActive && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if page == .expression {
                artwork
            } else {
                artwork
                    .frame(height: artworkHeight)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(page.artworkDescription)
                    .allowsHitTesting(false)
            }
            Text(page.title)
                .font(.system(size: page == .practice ? titleSize : storyTitleSize, weight: .bold))
                .foregroundStyle(AppTextColor.title)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(page.subtitle)
                .font(.body)
                .foregroundStyle(AppTextColor.secondary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: shouldAnimateAlbum) {
            guard page == .photo else { return }
            if reduceMotion {
                albumPhase = .photo
                return
            }
            guard shouldAnimateAlbum, albumPhase != .photo else { return }
            albumPhase = .album
            do {
                try await Task.sleep(for: .milliseconds(600))
                withAnimation(.easeInOut(duration: 0.9)) { albumPhase = .browsing }
                try await Task.sleep(for: .milliseconds(1100))
                withAnimation(.easeOut(duration: 0.2)) { albumPhase = .selected }
                try await Task.sleep(for: .milliseconds(550))
                withAnimation(.easeInOut(duration: 0.45)) { albumPhase = .photo }
            } catch {
                // This simulated album stops when the page or app is no longer active.
                return
            }
        }
        .task(id: shouldAnimatePractice) {
            practicePhase = .completeSentence
            guard shouldAnimatePractice else {
                practicePhase = .solved
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeInOut(duration: 0.25)) { practicePhase = .blank }
                try await Task.sleep(for: .seconds(1))
                for phase in [OnboardingPracticePhase.firstWord, .secondWord, .solved] {
                    try await Task.sleep(for: .milliseconds(700))
                    withAnimation(.easeInOut(duration: 0.25)) { practicePhase = phase }
                }
            } catch {
                // Switching pages or leaving the app cancels this visual-only demo.
                return
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        switch page {
        case .photo:
            OnboardingAlbumArtwork(phase: albumPhase)
        case .expression:
            OnboardingExpressionArtwork(isActive: isActive)
        case .practice:
            VStack(spacing: 16) {
                photo.frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    Text(practicePhase.sentence)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(practicePhase == .solved ? AppPalette.accentText : AppTextColor.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 84, alignment: .leading)
                    HStack(spacing: 8) {
                        ForEach(OnboardingPracticePhase.answers.indices, id: \.self) { index in
                            word(OnboardingPracticePhase.answers[index], selected: index < practicePhase.filledWordCount)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.apricot, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
            }
        }
    }

    private var photo: some View {
        GeometryReader { proxy in
            Image("OnboardingCafe")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }

    private func word(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(selected ? AppPalette.onAccent : AppTextColor.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? AppPalette.accent : AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
    }
}

struct OnboardingExpressionDemo {
    static let feelingSentence = "I could sit here all afternoon and do nothing."
    static let sentences = [
        "Sunlight fills this cozy cafe, with green plants by the window.",
        "The coffee is smooth and creamy, with a slightly bitter taste.",
        feelingSentence
    ]
    var visibleCount = 0
    var selectedIndex: Int?
    private(set) var hasInteracted = false

    mutating func toggleFavorite(at index: Int) {
        guard Self.sentences.indices.contains(index), index < visibleCount else { return }
        hasInteracted = true
        selectedIndex = selectedIndex == index ? nil : index
    }

    mutating func demonstrateFavorite() {
        guard !hasInteracted, visibleCount == Self.sentences.count else { return }
        selectedIndex = Self.sentences.count - 1
    }
}

struct OnboardingExpressionArtwork: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var demo = OnboardingExpressionDemo()
    @State private var showsTap = false
    @State private var hasFinished = false

    private var isPlaying: Bool {
        isActive && scenePhase == .active && !reduceMotion && !voiceOverEnabled
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(OnboardingExpressionDemo.sentences.indices, id: \.self) { index in
                sentenceCard(at: index)
                    .opacity(index < demo.visibleCount ? 1 : 0)
                    .offset(y: index < demo.visibleCount || reduceMotion ? 0 : 10)
                    .allowsHitTesting(index < demo.visibleCount)
                    .accessibilityHidden(index >= demo.visibleCount)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 100)
        .background {
            GeometryReader { geometry in
                Image("OnboardingCafe")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .task(id: isPlaying) {
            showsTap = false
            if reduceMotion || voiceOverEnabled {
                demo.visibleCount = OnboardingExpressionDemo.sentences.count
                demo.demonstrateFavorite()
                hasFinished = true
                return
            }
            guard isPlaying, !hasFinished else { return }
            do {
                // Reserve each card's space so the copy and photo stay still during the reveal.
                while demo.visibleCount < OnboardingExpressionDemo.sentences.count {
                    try await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeOut(duration: 0.5)) { demo.visibleCount += 1 }
                }
                try await Task.sleep(for: .milliseconds(850))
                if !demo.hasInteracted {
                    withAnimation(.easeOut(duration: 0.2)) { showsTap = true }
                    try await Task.sleep(for: .milliseconds(250))
                    withAnimation(.easeInOut(duration: 0.25)) { demo.demonstrateFavorite() }
                    try await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeOut(duration: 0.25)) { showsTap = false }
                }
                hasFinished = true
            } catch {
                showsTap = false
            }
        }
    }

    private func sentenceCard(at index: Int) -> some View {
        let selected = demo.selectedIndex == index
        let text = OnboardingExpressionDemo.sentences[index]
        let isDemoTap = showsTap && !demo.hasInteracted && index == 2
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                showsTap = false
                demo.toggleFavorite(at: index)
            }
        } label: {
            HStack(spacing: 10) {
                Text(text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? AppTextColor.primary : AppTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "star.fill" : "star")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? AppPalette.accentText : AppTextColor.tertiary)
                    .frame(width: 32, height: 44)
                    .scaleEffect(isDemoTap ? 0.9 : 1)
                    .overlay {
                        Circle()
                            .stroke(AppPalette.accent.opacity(isDemoTap ? 0.6 : 0), lineWidth: 2)
                            .frame(width: 40, height: 40)
                            .scaleEffect(isDemoTap ? 1.15 : 0.7)
                    }
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background((selected ? AppPalette.apricot : AppSurfaceColor.card).opacity(0.94),
                        in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
            .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityValue(selected
            ? L10n.string("favorites.hero.count_label", "已收藏")
            : L10n.string("onboarding.expression.not_saved", "未收藏"))
        .accessibilityHint(L10n.string("onboarding.expression.favorite_hint", "轻点切换示例收藏，不会保存到你的真实收藏。"))
    }
}

enum OnboardingAlbumPhase: CaseIterable {
    case album, browsing, selected, photo
}

struct OnboardingAlbumArtwork: View {
    let phase: OnboardingAlbumPhase
    // Bundled examples only: onboarding never opens or reads the user's photo library.
    static let thumbnails = [
        "LoginPreviewHiking", "LoginPreviewToddler", "LoginPreview",
        "LoginPreview", "LoginPreviewHiking", "LoginPreviewToddler",
        "LoginPreviewToddler", "OnboardingCafe", "LoginPreviewHiking",
        "LoginPreviewHiking", "LoginPreview", "LoginPreviewToddler"
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if phase == .photo {
                    Image("OnboardingCafe")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    album(width: geometry.size.width)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(AppSurfaceColor.card)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        }
    }

    private func album(width: CGFloat) -> some View {
        let side = max(1, (width - 32) / 3)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(AppPalette.accentText)
                Text(L10n.string("onboarding.album.title", "相册"))
                    .foregroundStyle(AppTextColor.title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            GeometryReader { _ in
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 4), count: 3), spacing: 4) {
                    ForEach(Self.thumbnails.indices, id: \.self) { index in
                        Image(Self.thumbnails[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                if phase == .selected && index == 7 {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(AppPalette.accent, lineWidth: 3)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if phase == .selected && index == 7 {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppPalette.onAccent, AppPalette.accent)
                                        .padding(5)
                                }
                            }
                            .opacity(phase == .selected && index != 7 ? 0.55 : 1)
                    }
                }
                .offset(y: phase == .album ? 0 : -(side + 4))
            }
            .clipped()
            .padding(.horizontal, 12)
        }
    }
}

enum OnboardingPracticePhase: CaseIterable {
    case completeSentence, blank, firstWord, secondWord, solved

    static let answers = ["sit", "afternoon", "nothing"]

    var filledWordCount: Int {
        switch self {
        case .completeSentence, .blank: 0
        case .firstWord: 1
        case .secondWord: 2
        case .solved: 3
        }
    }

    var sentence: String {
        guard self != .completeSentence else { return OnboardingExpressionDemo.feelingSentence }
        return Self.answers.dropFirst(filledWordCount).reduce(OnboardingExpressionDemo.feelingSentence) { sentence, word in
            sentence.replacingOccurrences(of: word, with: "____")
        }
    }
}
