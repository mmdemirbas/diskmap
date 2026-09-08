import DiskMapCore
import SwiftUI

extension CleanupSuggestion.Kind {
    var symbol: String {
        switch self {
        case .duplicateFolders: "folder.badge.minus"
        case .duplicateFiles: "doc.on.doc"
        case .buildOutput: "hammer"
        case .appCaches: "shippingbox"
        case .installers: "arrow.down.circle"
        case .stale: "clock.badge.exclamationmark"
        case .trash: "trash"
        }
    }
    var titleKey: L10n.K {
        switch self {
        case .duplicateFolders: .suggestFolders
        case .duplicateFiles: .suggestFiles
        case .buildOutput: .suggestBuild
        case .appCaches: .suggestCaches
        case .installers: .suggestInstallers
        case .stale: .suggestStale
        case .trash: .suggestTrash
        }
    }
    var explanationKey: L10n.K {
        switch self {
        case .duplicateFolders: .suggestFoldersWhy
        case .duplicateFiles: .suggestFilesWhy
        case .buildOutput: .suggestBuildWhy
        case .appCaches: .suggestCachesWhy
        case .installers: .suggestInstallersWhy
        case .stale: .suggestStaleWhy
        case .trash: .suggestTrashWhy
        }
    }
}

extension CleanupSuggestion.Safety {
    var key: L10n.K {
        switch self {
        case .comesBack: .safetyComesBack
        case .aCopyRemains: .safetyCopyRemains
        case .yourCall: .safetyYourCall
        }
    }
    var tint: Color {
        switch self {
        case .comesBack: .green
        case .aCopyRemains: .blue
        case .yourCall: .orange
        }
    }
}

/// Where the easy space is, safest first.
///
/// The ordering is the argument the screen makes: what a toolchain rebuilds by
/// itself comes before what leaves a copy behind, which comes before what only
/// the user can judge. Sorting by size instead would put the most consequential
/// decision at the top, which is exactly the wrong advice.
///
/// Nothing here deletes. Every row hands over to the same confirmation list
/// that a hand-made selection reaches, with every path spelled out.
struct CleanupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        ReadableColumn { column }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.suggestionsLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc[.computing]).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.suggestions.isEmpty {
                Text(loc[.nothingObviousToFree])
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                viewportScroller(renderMode: model.renderMode) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.suggestions) { row($0) }
                    }
                }
            }
            Divider()
            footer
        }
    }

    private var total: Int64 {
        model.suggestions.filter { !$0.nodes.isEmpty }.reduce(0) { $0 + $1.bytes }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc[.freeUpSpace]).font(.system(size: 15, weight: .semibold))
            Text(model.suggestions.isEmpty ? loc[.lookingForSpace]
                                           : loc.couldFreeAbout(shortBytes(total)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    private func row(_ suggestion: CleanupSuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.kind.symbol)
                .font(.system(size: 15)).foregroundStyle(suggestion.safety.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(loc[suggestion.kind.titleKey]).font(.system(size: 13, weight: .medium))
                    Text(loc[suggestion.safety.key])
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(suggestion.safety.tint.opacity(0.16), in: Capsule())
                        .foregroundStyle(suggestion.safety.tint)
                }
                Text(loc[suggestion.kind.explanationKey])
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if suggestion.omitted > 0 {
                    // Never let the screen imply it covered everything.
                    Text(loc.largestOfTotal(suggestion.itemCount,
                                            suggestion.itemCount + suggestion.omitted,
                                            shortBytes(suggestion.omittedBytes)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(shortBytes(suggestion.bytes))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                Text(loc.itemCount(suggestion.itemCount))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(width: 92, alignment: .trailing)
            action(suggestion).frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func action(_ suggestion: CleanupSuggestion) -> some View {
        if suggestion.nodes.isEmpty {
            Button(loc[.showInFinder]) { model.showTrashInFinder() }
                .controlSize(.small)
        } else {
            Button(loc[.reviewItems]) { model.review(suggestion) }
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(loc[.suggestionsNeverDelete], systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(loc[.exclusions]) { model.showExclusions = true }
                .buttonStyle(.borderless).controlSize(.small)
            Button(loc[.close]) { model.close(.space) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
