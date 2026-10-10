import CryptoKit
import ImageIO
import SwiftUI

struct FavoriteSentenceThumbnail: View {
    @EnvironmentObject private var appModel: AppModel
    let memoryID: UUID
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var decodedData = Data()
    @State private var decodedOwner: UUID?

    private struct LoadIdentity: Equatable {
        let accountRevision: UUID
        let memoryID: UUID
        let data: Data
        let remotePath: String?
        let isOnline: Bool
    }

    private var loadIdentity: LoadIdentity {
        let memory = appModel.memory(withID: memoryID)
        return LoadIdentity(
            accountRevision: appModel.accountRequests.revision, memoryID: memoryID,
            data: memory?.imageData ?? Data(), remotePath: memory?.remoteImagePath,
            isOnline: appModel.isNetworkAvailable
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppSurfaceColor.elevated
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if isLoading {
                    ProgressView().controlSize(.mini).tint(AppTextColor.secondary)
                } else {
                    Image(systemName: "photo")
                        .font(.body)
                        .foregroundStyle(AppTextColor.tertiary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: loadIdentity) {
            let identity = loadIdentity
            if decodedOwner != identity.accountRevision || decodedData != identity.data { image = nil }
            guard image == nil else { return }
            isLoading = true
            await appModel.ensureMemoryImageLoaded(memoryID: memoryID)
            guard !Task.isCancelled, appModel.accountRequests.revision == identity.accountRevision else { return }
            let data = appModel.memory(withID: memoryID)?.imageData ?? Data()
            let decoded = await Task.detached(priority: .utility) { FavoriteThumbnailDecoder.decode(data) }.value
            guard !Task.isCancelled, appModel.accountRequests.revision == identity.accountRevision else { return }
            decodedOwner = identity.accountRevision
            decodedData = data
            image = decoded
            isLoading = false
        }
    }
}

enum FavoriteThumbnailDecoder {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        cache.setObject(thumbnail, forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }
}
