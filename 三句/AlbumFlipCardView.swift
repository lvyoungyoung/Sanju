import ImageIO
import SwiftUI
import UIKit

struct AlbumFlipNeighborCard: View {
    let size: CGSize

    var body: some View {
        ZStack {
            AppSurfaceColor.elevated
            Ellipse()
                .fill(AppStroke.subtle)
                .frame(width: size.width * 1.3, height: size.height * 0.65)
                .offset(x: -size.width * 0.2, y: -size.height * 0.2)
            Ellipse()
                .fill(AppPalette.accent.opacity(0.07))
                .frame(width: size.width, height: size.height * 0.5)
                .offset(x: size.width * 0.2, y: size.height * 0.25)
        }
        .frame(width: size.width, height: size.height)
        .blur(radius: 24)
        .background(AppSurfaceColor.elevated)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct AlbumFlipFavoriteFeedbackView: View {
    let isFavorite: Bool
    var showsDoubleTapHint = true

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            Label(
                isFavorite
                    ? L10n.string("album_flip.saved", "已收藏")
                    : L10n.string("album_flip.unsaved", "已取消收藏"),
                systemImage: isFavorite ? "star.fill" : "star.slash"
            )
            .font(.headline)
            .foregroundStyle(AppPalette.accentText)

            if isFavorite && showsDoubleTapHint {
                Text(L10n.string("album_flip.favorite_feedback_hint", "双击也可以收藏哦"))
                    .font(.caption)
                    .foregroundStyle(AppTextColor.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

struct AlbumFlipFavoriteButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isFavorite ? AppPalette.accentText : AppTextColor.primary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(AppSurfaceColor.card, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(StudioPressStyle())
        .accessibilityLabel(isFavorite
            ? L10n.string("favorites.action.unfavorite", "取消收藏")
            : L10n.string("new.result.favorite", "收藏"))
        .accessibilityValue(isFavorite ? L10n.string("album_flip.saved", "已收藏") : "")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
        .accessibilityIdentifier("album_flip.favorite")
    }
}

struct AlbumFlipSentenceCard<Photo: View>: View {
    let item: AlbumFlipItem
    let size: CGSize
    let translatedSentenceIDs: Set<UUID>
    let onToggleTranslation: (UUID) -> Void
    var onDoubleTap: () -> Void = {}
    var showsJapaneseReadings = true
    @ViewBuilder var photo: () -> Photo

    var body: some View {
        VStack(spacing: 0) {
            photo()
                .frame(width: size.width, height: max(80, min(360, size.height * (item.sentences.count == 3 ? 0.34 : item.reply == nil ? 0.56 : 0.43))))
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onDoubleTap)
                .accessibilityLabel(L10n.string("album_flip.photo", "这句话对应的照片"))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let title = item.scenarioTitle {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTextColor.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(item.sentences) { sentence in
                        interactiveSentence(sentence)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, item.reply == nil ? 22 : 16)
                .padding(.top, item.reply == nil ? 20 : 16)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background {
            AppSurfaceColor.card
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onDoubleTap)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }

    private func interactiveSentence(_ sentence: SentenceRecord) -> some View {
        Group {
            if item.reply != nil {
                DialogueBubble(isReply: sentence.dialogue?.turn == 1,
                    incomingFill: AppSurfaceColor.elevated) {
                    sentenceContent(sentence)
                }
            } else {
                sentenceContent(sentence)
            }
        }
        .contentShape(Rectangle())
        // Resolve the double tap first so saving never also reveals a translation.
        .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { value in
            switch value {
            case .first: onDoubleTap()
            case .second: onToggleTranslation(sentence.id)
            }
        })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(translatedSentenceIDs.contains(sentence.id)
            ? L10n.string("album_flip.hide_translation", "收起翻译")
            : L10n.string("album_flip.show_translation", "查看翻译"))
        .accessibilityAction { onToggleTranslation(sentence.id) }
        .accessibilityIdentifier("album_flip.translation.\(sentence.id)")
    }

    private func sentenceContent(_ sentence: SentenceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sentenceText: sentence.targetText, language: item.context.teachingLocale.rawValue)
                .font(item.reply == nil
                    ? .custom("AvenirNext-DemiBold", size: 23, relativeTo: .title3)
                    : AppTypography.sentence)
                .foregroundStyle(AppTextColor.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            SentenceReadingView(sentence: sentence, context: item.context, isEnabled: showsJapaneseReadings)
            if translatedSentenceIDs.contains(sentence.id) {
                Text(sentenceText: sentence.translationText, language: item.context.translationLanguage.rawValue)
                    .font(item.reply == nil ? .body : .subheadline)
                    .foregroundStyle(AppTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

struct SentenceSpeakerBadge: View {
    @ScaledMetric(relativeTo: .caption) private var diameter = 26.0
    let speaker: String

    var body: some View {
        Text(speaker)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTextColor.secondary)
            .frame(width: diameter, height: diameter)
            .background(AppSurfaceColor.elevated, in: Circle())
            .accessibilityLabel(L10n.string("dialogue.speaker", "说话人") + " " + speaker)
    }
}

struct AlbumFlipPhoto: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let memoryID: UUID
    let isFront: Bool
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var retry = 0

    private struct LoadID: Hashable {
        let memoryID: UUID
        let byteCount: Int
        let isOnline: Bool
        let retry: Int
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppSurfaceColor.elevated
                if let image {
                    AlbumFlipPhotoImage(image: image, isFront: isFront, reduceMotion: reduceMotion)
                } else if isLoading {
                    ProgressView().tint(AppTextColor.secondary)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 32, weight: .light))
                            .accessibilityHidden(true)
                        Text(L10n.string("album_flip.photo_unavailable", "照片暂时无法加载"))
                            .font(.subheadline)
                        Button(L10n.string("common.retry", "重试")) { retry += 1 }
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 60, minHeight: 44)
                            .tint(AppPalette.accentText)
                    }
                    .foregroundStyle(AppTextColor.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: LoadID(
            memoryID: memoryID,
            byteCount: appModel.memory(withID: memoryID)?.imageData.count ?? 0,
            isOnline: appModel.isNetworkAvailable,
            retry: retry
        )) {
            guard image == nil else { return }
            isLoading = true
            await appModel.ensureMemoryImageLoaded(memoryID: memoryID)
            guard !Task.isCancelled else { return }
            let data = appModel.memory(withID: memoryID)?.imageData ?? Data()
            let decoded = await Task.detached(priority: .userInitiated) {
                AlbumFlipPhotoDecoder.decode(data)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
            isLoading = false
        }
    }
}

struct AlbumFlipPhotoImage: View {
    let image: UIImage
    let reduceMotion: Bool
    @State private var hasRevealed: Bool

    init(image: UIImage, isFront: Bool, reduceMotion: Bool) {
        self.image = image
        self.reduceMotion = reduceMotion
        // Buffered photos are already visible during a swipe; never hide them on promotion.
        _hasRevealed = State(initialValue: !isFront || reduceMotion)
    }

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .opacity(reduceMotion || hasRevealed ? 1 : 0)
        }
        .task {
            guard !hasRevealed else { return }
            if !reduceMotion {
                // Establish the transparent frame before a newly loaded photo fades in.
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            // Deck advancement disables layout animations; only the photo should animate here.
            var transaction = Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.18))
            transaction.disablesAnimations = reduceMotion
            withTransaction(transaction) { hasRevealed = true }
        }
    }
}

enum AlbumFlipPhotoDecoder {
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
