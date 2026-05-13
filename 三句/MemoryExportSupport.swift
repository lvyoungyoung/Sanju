import SwiftUI
import UIKit

private struct MemoryExportCardView: View {
    let memory: MemoryEntry

    private let exportWidth: CGFloat = 390
    private let exportImageHorizontalInset: CGFloat = 48

    private var exportImageWidth: CGFloat {
        exportWidth - exportImageHorizontalInset
    }

    private var exportImageHeight: CGFloat {
        exportImageWidth / exportImageAspectRatio
    }

    private var exportImage: UIImage? {
        UIImage(data: memory.imageData)
    }

    private var exportImageAspectRatio: CGFloat {
        guard let exportImage else {
            return AppImageAspectRatio.defaultDisplay
        }

        return AppImageAspectRatio.clamped(size: exportImage.size)
    }

    private var formattedDate: String {
        Self.dateFormatter.string(from: memory.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let image = exportImage {
                ZStack {
                    Color.white.opacity(0.38)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                    .frame(width: exportImageWidth, height: exportImageHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            }

            VStack(spacing: 12) {
                ForEach(memory.sentences) { sentence in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sentence.english)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.22))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(sentence.chinese)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.black.opacity(0.56))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
                }
            }

            Spacer(minLength: 14)

            HStack {
                Text(formattedDate)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(0.45))

                Spacer()

                Text(L10n.string("memory_export.created_with", "create with 三句"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.42))
            }
        }
        .padding(24)
        .frame(width: exportWidth)
        .background(Color(red: 0.92, green: 0.92, blue: 0.89))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter
    }()
}

@MainActor
enum MemoryExportRenderer {
    static func render(memory: MemoryEntry, displayScale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(
            content: MemoryExportCardView(memory: memory)
        )
        renderer.scale = displayScale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

final class PhotoLibrarySaver: NSObject {
    private let completion: (Error?) -> Void

    private init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    static func save(image: UIImage, completion: @escaping (Error?) -> Void) {
        let saver = PhotoLibrarySaver(completion: completion)
        UIImageWriteToSavedPhotosAlbum(
            image,
            saver,
            #selector(handleSave(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
        objc_setAssociatedObject(
            saver,
            Unmanaged.passUnretained(saver).toOpaque(),
            saver,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    @objc
    private func handleSave(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        completion(error)
        objc_removeAssociatedObjects(self)
    }
}
