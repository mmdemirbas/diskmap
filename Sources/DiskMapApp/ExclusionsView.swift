import DiskMapCore
import SwiftUI

/// Folders the app must never propose removing.
///
/// Deliberately not applied to the scan. Excluding a folder from measurement
/// would quietly make every total on screen wrong, and a disk tool that lies
/// about its numbers to be convenient is worse than one that suggests something
/// you did not want.
struct ExclusionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(loc[.exclusions]).font(.system(size: 15, weight: .semibold))
                Text(loc[.exclusionsExplained])
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
            Divider()

            if model.excludedPaths.isEmpty {
                Text(loc[.noExclusions]).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                viewportScroller(renderMode: model.renderMode) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.excludedPaths, id: \.self) { path in row(path) }
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button(loc[.addExclusion]) { model.chooseExclusion() }
                Spacer()
                Button(loc[.close]) { model.showExclusions = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .frame(width: 620, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 14)
            Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            Button(loc[.removeExclusion]) { model.unexclude(path) }
                .controlSize(.small).buttonStyle(.borderless)
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }
}
