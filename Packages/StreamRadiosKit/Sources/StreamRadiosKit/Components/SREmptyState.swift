import SwiftUI

/// Centred icon + message + optional actions, used for every "nothing to show" case.
public struct SREmptyState<Actions: View>: View {
    private let systemImage: String
    private let title: String
    private let message: String?
    private let actions: Actions

    public init(
        systemImage: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: SRSpacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(SRColor.tertiaryText)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: SRSpacing.sm) {
                Text(title)
                    .font(SRFont.sectionTitle)
                    .foregroundStyle(SRColor.primaryText)

                if let message {
                    Text(message)
                        .font(SRFont.rowSubtitle)
                        .foregroundStyle(SRColor.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            actions
        }
        .padding(.horizontal, SRSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
