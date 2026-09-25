import ImageIO
import SwiftUI
import UIKit

struct AlbumFlipSentenceCard<Photo: View>: View {
    let item: AlbumFlipItem
    let size: CGSize
    let showsTranslation: Bool
    let onToggleTranslation: () -> Void
    @ViewBuilder var photo: () -> Photo

    var body: some View {
        VStack(spacing: 0) {
            photo()
                .frame(width: size.width, height: max(80, min(360, size.height * 0.56)))
                .clipped()
                .accessibilityLabel(L10n.string("album_flip.photo", "这句话对应的照片"))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.sentence.english)
                        .font(.custom("AvenirNext-DemiBold", size: 23, relativeTo: .title3))
                        .foregroundStyle(AppTextColor.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsTranslation {
                        Text(item.sentence.chinese)
                            .font(.body)
                            .foregroundStyle(AppTextColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }

                    Button(action: onToggleTranslation) {
                        HStack(spacing: 6) {
                            Text(showsTranslation
                                ? L10n.string("album_flip.hide_translation", "收起翻译")
                                : L10n.string("album_flip.show_translation", "查看翻译"))
                            Image(systemName: showsTranslation ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(AppTextColor.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(AppSurfaceColor.card)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }
}

struct AlbumFlipPhoto: View {
    @EnvironmentObject private var appModel: AppModel
    let memoryID: UUID
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
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
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
