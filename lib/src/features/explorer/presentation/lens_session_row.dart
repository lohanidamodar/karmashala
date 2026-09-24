import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/agent_state_providers.dart';
import '../application/agent_states.dart';
import '../application/checkout.dart';
import '../application/explorer_actions.dart';
import '../application/workspace_session_entry.dart';

/// A session row in a cross-project lens: its state glyph, title and age, and
/// a second line naming where it lives. Each row watches only its own facts,
/// so a list of five hundred that shows thirty pays for thirty.
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

    return ExplorerRow(
      kind: ExplorerRowKind.session,
      depth: 0,
      selected: selected,
      settled: state == AgentState.ended,
      onTap: () => _open(context, ref),
      builder: (context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: ExplorerRow.glyphSlot,
            height: 18,
            child: Center(
              child: _StateGlyph(state: state, entry: entry),
            ),
          ),
          const SizedBox(width: ExplorerRow.textGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: density.rowTitle(
                    theme,
                    strong: state == AgentState.needsYou,
                  ),
                ),
                if (clauses.isNotEmpty)
                  Text(
                    clauses.join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
              ],
            ),
          ),
          if (dated) ...[
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
  const _StateGlyph({required this.state, required this.entry});

  final AgentState state;
  final WorkspaceSessionEntry entry;

  @override
  Widget build(BuildContext context) {
    const size = ExplorerRow.glyphSize;
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
