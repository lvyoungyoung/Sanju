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
                .foregroundStyle(AppTextColor.primary)
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
            .fill(AppSurfaceColor.secondaryFill)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(.systemBackground).opacity(0.28),
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
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
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
                    .foregroundStyle(AppTextColor.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(sentence.chinese)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTextColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                MemoryDetailActionCircle(
                    background: AppSurfaceColor.elevated,
                    icon: "play.fill",
                    iconColor: Color(red: 0.98, green: 0.65, blue: 0.00)
                ) {
                    appModel.speech.speak(sentence.english)
                }

                MemoryDetailActionCircle(
                    background: AppSurfaceColor.elevated,
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
            MemoryDetailPagerButton(
                title: L10n.string("memory_detail.pager.previous", "上一张"),
                isEnabled: canGoPrevious,
                action: onPrevious
            )

            Spacer()

            MemoryDetailPagerButton(
                title: L10n.string("memory_detail.pager.next", "下一张"),
                isEnabled: canGoNext,
                action: onNext
            )
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
            .foregroundStyle(AppTextColor.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
