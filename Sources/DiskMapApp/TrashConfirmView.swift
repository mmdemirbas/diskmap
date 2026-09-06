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
            // Always here, visible only when it applies. Ticking a synced file
            // used to insert this block and push the whole list down under the
            // pointer — during the one review whose entire job is to make sure
            // the right things are being removed.
            syncWarning(plan?.synced ?? [])
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
                Text(loc.alsoCovered(plan?.coveredByAnAncestor ?? 0))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .opacity((plan?.coveredByAnAncestor ?? 0) > 0 ? 1 : 0)
                    .accessibilityHidden((plan?.coveredByAnAncestor ?? 0) == 0)
            }
            // The rest of "you ticked more than this list shows". Both were
            // counted and never said out loud, which left the reviewer to
            // notice on their own that the list is shorter than the selection.
            //
            // One Text rather than one per reason: an invisible zero-count
            // sibling still takes its width, which pushed whichever line did
            // apply into the middle of the sheet. The line is reserved whether
            // or not it applies, because ticking recomputes both numbers.
            Text(asides.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .lineLimit(1, reservesSpace: true)
                .accessibilityHidden(asides.isEmpty)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    /// Ticked, and not on the list below, for a reason worth saying.
    private var asides: [String] {
        guard let plan else { return [] }
        var out: [String] = []
        if plan.alreadyGone > 0 { out.append(loc.alreadyGone(plan.alreadyGone)) }
        if plan.excluded > 0 { out.append(loc.onNeverTouchList(plan.excluded)) }
        return out
    }

    /// The one thing the Trash cannot take back. Above the list, in the warning
    /// colour — not a badge on a row that scrolls out of sight.
    private func syncWarning(_ synced: [TrashCandidate]) -> some View {
        let applies = !synced.isEmpty
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
            // Two lines whatever the sentence, so the block is the same
            // height in every language and at every window width.
            Text(loc[.alsoDeletedFromService])
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(applies ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.orange.opacity(applies ? 0.45 : 0)))
        .padding(.horizontal, 18).padding(.bottom, 12)
        .opacity(applies ? 1 : 0)
        .accessibilityHidden(!applies)
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
                wasItRead(group.id)
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
        // The last one left cannot be ticked: something has to survive. Nor can
        // anything on the never-touch list, which the copy report does not
        // filter by — the row used to tick and then read "Trash" beside an item
        // the planner would drop.
        let neverTouch = !going && model.isNeverTouch(member.node)
        let blocked = neverTouch
            || (!going && group.isCopyGroup && model.wouldBeTheLastCopy(member.node))
        return HStack(spacing: 9) {
            Image(systemName: going ? "trash.circle.fill" : "checkmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(going ? AnyShapeStyle(Color.red)
                                       : AnyShapeStyle(blocked ? .tertiary : .secondary))
                .onTapGesture { if !blocked { model.toggleChecked(member.node) } }
                .help(neverTouch ? loc[.refuseExcluded]
                                 : (blocked ? loc[.keepsOneCopy] : loc[.tickToChange]))

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
                    // A row that will not tick looks exactly like one that
                    // will, and the reason was only in a tooltip.
                    if neverTouch {
                        Text(loc[.neverTouchBadge])
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
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

    /// Whether the bytes behind this group were actually read.
    ///
    /// The group is a claim made from names and sizes. The screen it came from
    /// says whether that claim was checked; this is the screen where things go
    /// to the Trash, and it was not repeating it. The same sentence belongs at
    /// the moment of the decision, not one screen before it.
    @ViewBuilder private func wasItRead(_ id: Int64) -> some View {
        // `.orange` rather than the palette's warning, matching the screen this
        // verdict is repeated from — the two must read as the same statement.
        let outcome = model.verifications[id]?.outcome
        if let outcome {
            if outcome.cancelled {
                mark("pause.circle", .secondary, loc[.verifyStopped])
            } else if outcome.identical {
                mark("checkmark.seal.fill", .green, loc[.verifyIdentical])
            } else if outcome.distinct > 1 {
                mark("xmark.circle.fill", .orange, loc.verifyDiffer(outcome.distinct))
            } else {
                mark("questionmark.circle", .orange,
                     loc.verifyPartial(outcome.unread + outcome.skipped))
            }
        } else {
            mark("questionmark.circle", .secondary, loc[.reviewNotRead])
        }
    }

    private func mark(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .lineLimit(1).fixedSize()
    }

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
