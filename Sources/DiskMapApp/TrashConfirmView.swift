import DiskMapCore
import SwiftUI

/// The last thing between a selection and the Trash — and the place to change
/// that selection, not only to agree with it.
///
/// Copies are shown as whole groups: every copy, kept and removed alike, on one
/// card. "Delete this one" is not a judgement anybody can make without seeing
/// which one survives, and the earlier version showed only the victims. Ticking
/// is live, so the total at the bottom is always the total of what is ticked
/// right now, and *Keep this one* flips the whole decision in a single click.
struct TrashConfirmView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    let groups: [ReviewGroup]

    private var plan: TrashPlan? { model.reviewPlan }
    private var goingCount: Int { plan?.items.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let synced = plan?.synced, !synced.isEmpty { syncWarning(synced) }
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 720, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc[.reviewWhatGoes]).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Label(loc[.tickToChange], systemImage: "hand.tap")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let plan, plan.coveredByAnAncestor > 0 {
                    Text(loc.alsoCovered(plan.coveredByAnAncestor))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    /// The one thing the Trash cannot take back. Above the list, in the warning
    /// colour — not a badge on a row that scrolls out of sight.
    private func syncWarning(_ synced: [TrashCandidate]) -> some View {
        let providers = Array(Set(synced.compactMap(\.syncProvider))).sorted()
            .formatted(.list(type: .and))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.system(size: 12))
                Text(loc[.syncWarningTitle]).font(.system(size: 12, weight: .semibold))
                Text(loc.syncedItemCount(synced.count, providers))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(loc[.alsoDeletedFromService])
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.45)))
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var list: some View {
        viewportScroller(renderMode: model.renderMode) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { card($0) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    // MARK: - One decision

    private func card(_ group: ReviewGroup) -> some View {
        let staying = group.members.filter { !model.checked.contains($0.node) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: group.isCopyGroup ? "doc.on.doc" : iconFor(group.members[0]))
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                // Naming the card after one member is misleading when the
                // copies are named differently — and a renamed copy is exactly
                // what folder matching is good at finding.
                Text(Set(group.members.map(\.name)).count == 1
                     ? group.name : loc[.sameContentsDifferentNames])
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if group.isCopyGroup {
                    Text(loc.keepingOf(staying.count, group.members.count))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))

            ForEach(group.members) { member in
                Divider()
                memberRow(member, in: group)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func memberRow(_ member: ReviewMember, in group: ReviewGroup) -> some View {
        let going = model.checked.contains(member.node)
        // The last one left cannot be ticked: something has to survive.
        let blocked = !going && group.isCopyGroup && model.wouldBeTheLastCopy(member.node)
        return HStack(spacing: 9) {
            Image(systemName: going ? "trash.circle.fill" : "checkmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(going ? AnyShapeStyle(Color.red)
                                       : AnyShapeStyle(blocked ? .tertiary : .secondary))
                .onTapGesture { if !blocked { model.toggleChecked(member.node) } }
                .help(blocked ? loc[.keepsOneCopy] : loc[.tickToChange])

            Text(going ? loc[.willBeTrashed] : loc[.willStay])
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(going ? .red : .green)
                .frame(width: 68, alignment: .leading)

            Text(shortBytes(member.bytes))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 66, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.path)
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(going ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    if let provider = member.syncProvider {
                        Text(provider)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if member.isDirectory {
                    Text(loc.itemCount(member.itemCount))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)

            if group.isCopyGroup, going {
                Button(loc[.keepThisOne]) { model.keepOnly(member.node, in: group) }
                    .controlSize(.small).buttonStyle(.borderless)
            }
            Button {
                model.reveal(member.node)
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
            }
            .buttonStyle(.borderless).help(loc[.revealInFinder])
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(going ? Color.red.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !blocked { model.toggleChecked(member.node) } }
        .contextMenu {
            Button(loc[.revealInFinder]) { model.reveal(member.node) }
            Button(loc[.copyPath]) { model.copyPath(member.node) }
            Divider()
            // The one-click version of "stop offering me this".
            Button(loc[.neverSuggest]) { model.exclude(member.path) }
        }
    }

    private func iconFor(_ member: ReviewMember) -> String {
        member.isDirectory ? "folder.fill" : "doc.fill"
    }

    // MARK: - Acting

    private var footer: some View {
        HStack(spacing: 10) {
            if let refusal = model.reviewRefusalText {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Label(loc[.trashIsRecoverable], systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc[.exclusions]) { model.showExclusions = true }
                .buttonStyle(.borderless).controlSize(.small)
            Button(loc[.cancel]) { model.cancelBulkTrash() }
                .keyboardShortcut(.cancelAction)
            Button(role: .destructive) {
                model.confirmBulkTrash()
            } label: {
                Text(goingCount == 0 ? loc[.moveToTrash]
                                     : loc.moveCountToTrash(goingCount,
                                                            shortBytes(plan?.bytes ?? 0)))
            }
            .disabled(goingCount == 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
