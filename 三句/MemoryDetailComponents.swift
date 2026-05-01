import SwiftUI
import UIKit

struct SaveResultHUD: View {
    let message: String
    let isSuccess: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(
                    isSuccess
                    ? Color(red: 0.98, green: 0.65, blue: 0.00)
                    : Color(red: 0.88, green: 0.37, blue: 0.24)
                )

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.24, green: 0.24, blue: 0.24))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 188)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .stroke(AppStroke.highlight.opacity(0.75), lineWidth: 1)
        )
        .appCardShadow()
    }
}

struct MemoryDetailImageSkeleton: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
            .fill(Color.gray.opacity(0.14))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.28),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .rotationEffect(.degrees(22))
                    .frame(width: proxy.size.width * 0.55, height: proxy.size.height * 1.4)
                    .offset(x: proxy.size.width * phase)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

struct MemoryDetailSentencePanel: View {
    let memory: MemoryEntry

    var body: some View {
        VStack(spacing: 10) {
            ForEach(memory.sentences) { sentence in
                MemoryDetailSentenceRow(sentence: sentence)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            }
        }
    }
}

struct MemoryDetailSentenceRow: View {
    @EnvironmentObject private var appModel: AppModel
    let sentence: SentenceRecord

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(alignment: .leading, spacing: 18) {
                Text(sentence.english)
                    .font(.system(size: 17))
                    .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(sentence.chinese)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                MemoryDetailActionCircle(
                    background: Color(red: 0.98, green: 0.95, blue: 0.91),
                    icon: "play.fill",
                    iconColor: Color(red: 0.98, green: 0.65, blue: 0.00)
                ) {
                    appModel.speech.speak(sentence.english)
                }

                MemoryDetailActionCircle(
                    background: Color(red: 0.97, green: 0.97, blue: 0.97),
                    icon: sentence.isFavorite ? "star.fill" : "star",
                    iconColor: sentence.isFavorite ? Color(red: 0.98, green: 0.75, blue: 0.15) : Color(red: 0.78, green: 0.78, blue: 0.78)
                ) {
                    appModel.toggleFavorite(sentenceID: sentence.id)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct MemoryDetailActionCircle: View {
    let background: Color
    let icon: String
    let iconColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct MemoryDetailPagerControls: View {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            MemoryDetailPagerButton(title: "上一张", isEnabled: canGoPrevious, action: onPrevious)

            Spacer()

            MemoryDetailPagerButton(title: "下一张", isEnabled: canGoNext, action: onNext)
        }
    }
}

private struct MemoryDetailPagerButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Button(action: action) {
                    label
                }
                .buttonStyle(.glass)
            } else {
                Button(action: action) {
                    label
                        .background(.ultraThinMaterial, in: Capsule())
                        .appCardShadow()
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!isEnabled)
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.22))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
