import 'package:karmashala_git/repositories.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/agent_state_providers.dart';
import '../application/agent_states.dart';
import '../application/explorer_actions.dart';
import '../application/session_selection.dart';
import '../application/workspace_session_entry.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import 'explorer_selection_actions.dart';
import 'section_membership_dialog.dart';
import 'session_row_menu.dart';
import 'sidebar_chrome.dart';

/// A session row in a cross-project lens, on one line: its state glyph, its
/// title, where it lives, and its age — or, while it waits on the user, that
/// it waits. Each row watches only its own facts, so a list of five hundred
/// that shows thirty pays for thirty.
///
/// Selectable like the tree's rows: Ctrl-click ticks, Shift-click ranges over
/// the enclosing [SelectionOrderScope], and a ticked row's menu acts on the
/// whole selection.
class LensSessionRow extends ConsumerWidget {
  const LensSessionRow({required this.entry, super.key});

  final WorkspaceSessionEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = entry.id;
    final selected = entry.isImported
        ? ref.watch(selectedImportedSessionIdProvider.select((s) => s == id))
        : ref.watch(selectedSessionIdProvider.select((s) => s == id));
    final needsYou = ref.watch(
      needsYouProvider.select((byId) => byId.containsKey(id)),
    );
    final live = ref.watch(liveAgentStatusesProvider.select((m) => m[id]));
    final quiet = ref.watch(
      quietSessionsProvider.select((q) => q.contains(id)),
    );
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final ticked = ref.watch(
      sessionSelectionProvider.select((s) => s.contains(id)),
    );
    // Flips only when the selection's kind does, so a tick moves no other row.
    final tickEnabled = ref.watch(
      sessionSelectionProvider.select((s) => s.canTick(SelectionKind.sessions)),
    );
    final state = agentStateOf(
      needsYou: needsYou,
      live: live,
      rowStatus: entry.rowStatus,
      archived: entry.native?.isArchived ?? false,
      quiet: quiet,
    );
    final now = ref.read(clockProvider).nowUtc();
    final branch = _knownBranch(ref, entry.directory);
    // Read fresh, not from [entry], whose time is the list's snapshot.
    final quietSince = state == AgentState.quiet
        ? ref.read(sessionStatusLookupProvider)(id)?.evidenceAt
        : null;
    final clauses = [
      if (quietSince != null)
        'nothing new for ${compactAge(now.difference(quietSince))}',
      ...sessionContextClauses(
        projectName: entry.projectName,
        folder: entry.folder,
        branch: branch,
      ),
    ];
    final dated = entry.native != null || entry.imported != null;
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);

    final waiting = state == AgentState.needsYou;
    // What it waits on, in one word (board N1): "approve" or "question" when
    // the status source could tell, "waiting" when it could not. Read, not
    // watched: [needsYou] and [live] already wake the row when it changes.
    final waitKind = waiting
        ? ref.read(sessionStatusLookupProvider)(id)?.waiting
        : null;
    final terminals =
        ref.watch(availableSystemTerminalsProvider).asData?.value ?? const [];
    final hasSections = SectionMembershipDialog.hasManualSections(ref);
    // Read when the menu opens; the row draws no pin of its own.
    bool isPinned() =>
        ref.read(settingsControllerProvider).pinnedSessionIds.contains(id);
    final order = SelectionOrderScope.maybeOf(context);
    void tap() {
      if (!handleSelectableClick(
        ref,
        id: id,
        kind: SelectionKind.sessions,
        order: order,
      )) {
        _open(context, ref);
      }
    }

    return ExplorerRow(
      kind: ExplorerRowKind.session,
      minHeight: Sidebar.rowHeight,
      depth: 0,
      selected: selected || ticked,
      needsYou: waiting,
      settled: state == AgentState.ended,
      onTap: tap,
      // The project tree's session menu, headed by Open; an imported
      // conversation's "Resume" is that same Open, so it is not offered twice.
      menuItemsBuilder: () =>
          selectionRowMenu(ref, context, id) ??
          [
            DesktopMenuItem(value: 'open', label: 'Open', icon: AppIcons.play),
            ...switch ((entry.native, entry.imported)) {
              (final Session native, _) => nativeSessionMenuItems(
                ref,
                native,
                pinned: isPinned(),
                hasSections: hasSections,
                terminals: terminals,
              ),
              (_, ImportedSession()) => importedSessionMenuItems(
                pinned: isPinned(),
                hasSections: hasSections,
                terminals: terminals,
                resume: false,
              ),
              _ => [selectRowMenuItem()],
            },
          ],
      onMenu: (action) async {
        if (runSelectionRowAction(
          ref,
          context,
          action,
          id: id,
          kind: SelectionKind.sessions,
        )) {
          return;
        }
        if (action == 'open') return _open(context, ref);
        final native = entry.native;
        final imported = entry.imported;
        if (native != null) {
          await runNativeSessionMenuAction(
            context,
            ref,
            native,
            action,
            terminals: terminals,
          );
        } else if (imported != null) {
          await runImportedSessionMenuAction(
            context,
            ref,
            imported,
            action,
            terminals: terminals,
          );
        }
      },
      builder: (context) => Row(
        children: [
          if (selecting)
            SizedBox(
              width: ExplorerRow.glyphSlot,
              child: Center(
                child: ExplorerRowTick(
                  value: ticked,
                  semanticLabel: 'Select "${entry.title}"',
                  onChanged: tickEnabled ? tap : null,
                  disabledTooltip: SelectionKind.projects.holdsLabel,
                ),
              ),
            ),
          SizedBox(
            width: ExplorerRow.glyphSlot,
            child: Center(
              child: _StateGlyph(state: state, entry: entry, wait: waitKind),
            ),
          ),
          const SizedBox(width: ExplorerRow.textGap),
          // The title first; where it lives after it, muted, on the same line
          // and the first to give way.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  flex: 3,
                  child: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: density.rowTitle(theme, strong: waiting),
                  ),
                ),
                if (clauses.isNotEmpty) ...[
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    flex: 2,
                    child: Text(
                      clauses.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (waiting) ...[
            const SizedBox(width: Insets.xs),
            Text(
              switch (waitKind) {
                AgentWaitKind.approval => 'approve',
                AgentWaitKind.question => 'question',
                _ => 'waiting',
              },
              style: muted?.copyWith(
                color: SemanticColors.of(context).attention,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (dated) ...[
            const SizedBox(width: Insets.xs),
            Text(compactAge(now.difference(entry.activityAt)), style: muted),
          ],
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final actions = ref.read(explorerActionsProvider);
    final native = entry.native;
    final imported = entry.imported;
    final ExplorerResult? result;
    if (native != null) {
      result = await actions.openNative(native.id);
    } else if (imported != null) {
      result = await actions.openImported(imported);
    } else {
      // No row behind it: select what the inbox would, which is nothing when
      // the row is gone.
      focusWatchedSession(ref.container, openId: entry.id, imported: false);
      result = null;
    }
    final message = result?.message;
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

/// The branch a reading of [directory] has already named, or null. Borrowed,
/// never asked for: `exists` creates nothing, and the readings counter wakes
/// the row when somebody else's `git status` lands.
String? _knownBranch(WidgetRef ref, EnvironmentPath? directory) {
  if (directory == null) return null;
  final checkout = Checkout(directory);
  ref.watch(checkoutReadingsProvider.select((r) => r[checkout]));
  final provider = checkoutDeliveryProvider(checkout);
  if (!ref.exists(provider)) return null;
  return ref.read(provider).asData?.value.branch;
}

class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.state, required this.entry, this.wait});

  final AgentState state;
  final WorkspaceSessionEntry entry;

  /// What a waiting session waits on, when known.
  final AgentWaitKind? wait;

  @override
  Widget build(BuildContext context) {
    const size = ExplorerRow.glyphSize;
    // Board N1: an approval breathes a shield, a question wears its mark.
    if (state == AgentState.needsYou && wait == AgentWaitKind.approval) {
      return AskGlyph(size: size, semanticLabel: state.label);
    }
    if (state == AgentState.needsYou && wait == AgentWaitKind.question) {
      return Icon(
        AppIcons.question,
        size: size,
        color: SemanticColors.of(context).attention,
        semanticLabel: state.label,
      );
    }
    final status = switch (state) {
      AgentState.needsYou => AgentActivityStatus.awaitingApproval,
      AgentState.quiet || AgentState.working => AgentActivityStatus.working,
      AgentState.failed => AgentActivityStatus.failed,
      AgentState.ready => AgentActivityStatus.idle,
      AgentState.ended => null,
    };
    // The words, not the colour, carry the state to a screen reader.
    if (status != null) {
      return StatusGlyph(
        status: status,
        size: size,
        semanticLabel: state.label,
      );
    }
    return Icon(
      entry.isImported ? AppIcons.clockCounterClockwise : AppIcons.checkCircle,
      size: size,
      semanticLabel: state.label,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}
