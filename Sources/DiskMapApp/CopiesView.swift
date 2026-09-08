import SwiftUI

/// The copy report as a tool rather than as one of the map's side panels.
///
/// The list is the same either way — what changes is the room it gets. In the
/// side panel it has 470 points and every path is truncated from the head; here
/// it has the window, held to a measure a row can be read across.
///
/// Both still exist on purpose. The panel answers "is there anything duplicated
/// in the folder I am looking at", beside the map that put the question there.
/// The tool answers "where are my duplicates", and is where you go when that is
/// the job rather than a detail of another one.
struct CopiesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        ReadableColumn {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                DuplicatesView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(loc[.tabDuplicates]).font(.system(size: 15, weight: .semibold))
            Text(loc[.copiesSubtitle])
                .font(.system(size: 11)).foregroundStyle(.secondary)
                // Two lines whatever the sentence, so the list below starts at
                // the same place in every language.
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
