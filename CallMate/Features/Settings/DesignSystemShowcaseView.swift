//
//  DesignSystemShowcaseView.swift
//  CallMate
//

import SwiftUI

struct DesignSystemShowcaseView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Spacing.x3) {
                headerSection
                metricsSection
                actionSection
            }
            .padding(DS.Spacing.x2)
        }
        .background(DS.ColorToken.background.ignoresSafeArea())
        .navigationTitle("Design System")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x1) {
            Text("AI Generated UI")
                .font(DS.Typography.title)
                .foregroundColor(DS.ColorToken.text)
            Text("Only DS tokens + native SwiftUI + SF Symbols")
                .font(DS.Typography.caption)
                .foregroundColor(DS.ColorToken.subtext)
        }
    }

    private var metricsSection: some View {
        VStack(spacing: DS.Spacing.x2) {
            metricRow(icon: "paintpalette.fill", title: "Color Palette", value: "Primary + Accent + Neutral")
            metricRow(icon: "textformat.size", title: "Type Scale", value: "Title / Body / Caption")
            metricRow(icon: "square.grid.3x3.fill", title: "Spacing", value: "8 / 16 / 24 / 32 / 48")
        }
        .padding(DS.Spacing.x2)
        .dsCardStyle()
    }

    private var actionSection: some View {
        VStack(spacing: DS.Spacing.x2) {
            Button {
                // demo action
            } label: {
                HStack(spacing: DS.Spacing.x1) {
                    Image(systemName: "sparkles")
                    Text("Generate New Screen")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .dsPrimaryButtonStyle()

            HStack(spacing: DS.Spacing.x1) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(DS.ColorToken.accent)
                Text("Rounded corners, spacing, and hierarchy are unified.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.ColorToken.subtext)
            }
        }
        .padding(DS.Spacing.x2)
        .dsCardStyle()
    }

    private func metricRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: DS.Spacing.x2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DS.ColorToken.primary)
                .frame(width: 36, height: 36)
                .background(DS.ColorToken.primary.opacity(0.12))
                .cornerRadius(DS.Radius.button)

            VStack(alignment: .leading, spacing: DS.Spacing.x1) {
                Text(title)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(DS.ColorToken.text)
                Text(value)
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.ColorToken.subtext)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    NavigationStack {
        DesignSystemShowcaseView()
    }
}
