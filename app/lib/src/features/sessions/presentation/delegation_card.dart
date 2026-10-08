import 'package:agent_cli/stream.dart'
    show delegatedChildIdOf, isDelegationToolName;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/explorer_actions.dart';
import '../application/session_subagents_providers.dart';
import 'chat_transcript.dart';
import 'session_subagents_panel.dart'
    show formatSubagentDuration, subagentDuration, subagentStateLook;

/// One child-starting call in a parent's chat: the child it started, once
/// the call answered, and what it was asked.
class DelegationCall {
  const DelegationCall({this.title, this.childId});

  /// What the call names it by; null when it carried no subject, as an ACP
  /// agent's call does — the child's own session title stands in.
  final String? title;
  final String? childId;
}

/// The child-starting calls of each turn that made two or more, keyed by the
/// row the folded card hangs under: the turn's first words after the calls,
/// else its last words before them. A turn's calls sit in a folded tool run,
/// so the card is never hung on one of them.
Map<int, List<DelegationCall>> delegationGroups(List<ChatMessage> messages) {
  final groups = <int, List<DelegationCall>>{};
  var turnStart = 0;
  void close(int end) {
    final calls = <DelegationCall>[];
    int? first, last;
    for (var i = turnStart; i < end; i++) {
      final tool = messages[i].tool;
      if (tool == null || !isDelegationToolName(tool.name)) continue;
      first ??= i;
      last = i;
      final subject = tool.subject?.split('\n').first.trim();
      calls.add(
        DelegationCall(
          title: subject == null || subject.isEmpty ? null : subject,
          childId: delegatedChildIdOf(tool.output),
        ),
      );
    }
    if (calls.length < 2) return;
    int? anchor;
    for (var i = last! + 1; i < end && anchor == null; i++) {
      if (messages[i].role != 'tool') anchor = i;
    }
    for (var i = first! - 1; i >= turnStart && anchor == null; i--) {
      if (messages[i].role != 'tool') anchor = i;
    }
    if (anchor != null) groups[anchor] = calls;
  }

  for (var i = 0; i < messages.length; i++) {
    if (messages[i].role != 'user' || i == turnStart) continue;
    close(i);
    turnStart = i;
  }
  close(messages.length);
  return groups;
}

/// [groups] as one comparable string, so a re-parse that found the same
/// groups keeps the rows' detail builder.
String delegationGroupsKey(Map<int, List<DelegationCall>> groups) => [
  for (final MapEntry(:key, :value) in groups.entries)
    '$key:${value.map((c) => '${c.childId}/${c.title}').join(',')}',
].join(';');

/// **Children started together, as one folded card** in the parent's chat:
/// how many and how far they got; opened, each child's agent, model, state,
/// duration and answer, read from `sessions.subagents`.
class DelegationGroupCard extends ConsumerStatefulWidget {
  const DelegationGroupCard({
    required this.parentSessionId,
    required this.calls,
    super.key,
  });

  final String parentSessionId;
  final List<DelegationCall> calls;

  @override
  ConsumerState<DelegationGroupCard> createState() =>
      _DelegationGroupCardState();
}

class _DelegationGroupCardState extends ConsumerState<DelegationGroupCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = {
      for (final entry
          in ref
                  .watch(sessionSubagentsProvider(widget.parentSessionId))
                  .asData
                  ?.value
                  .entries ??
              const <SessionSubagent>[])
        entry.id: entry,
    };
    final calls = widget.calls;
    final states = [
      for (final call in calls)
        call.childId == null ? null : entries[call.childId]?.state,
    ];
    final counts = <String, int>{};
    for (final state in states) {
      final label = state == null
          ? 'starting'
          : subagentStateLook(state).label.toLowerCase();
      counts[label] = (counts[label] ?? 0) + 1;
    }
    final summary = [
      for (final MapEntry(:key, :value) in counts.entries) '$value $key',
    ].join(' · ');
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: _open,
              child: InkWell(
                key: const ValueKey('delegation-card'),
                onTap: () => setState(() => _open = !_open),
                borderRadius: BorderRadius.circular(Radii.sm),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Touch.target),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.md,
                      vertical: Insets.sm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _open ? AppIcons.caretDown : AppIcons.caretRight,
                          size: Chrome.iconSmall,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: Insets.sm),
                        Icon(
                          AppIcons.treeStructure,
                          size: Chrome.iconSmall,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: Insets.sm),
                        Flexible(
                          child: Text(
                            'Delegated ${calls.length} sessions',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_open)
              for (final call in calls)
                _ChildLine(
                  call: call,
                  entry: call.childId == null ? null : entries[call.childId],
                ),
          ],
        ),
      ),
    );
  }
}

class _ChildLine extends ConsumerWidget {
  const _ChildLine({required this.call, required this.entry});

  final DelegationCall call;
  final SessionSubagent? entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = this.entry;
    final duration = entry == null
        ? null
        : subagentDuration(entry, ref.read(clockProvider).nowUtc());
    final facts = entry == null
        ? (call.childId == null ? 'starting' : 'not listed yet')
        : [
            entry.agent ?? 'session',
            ?entry.model,
            subagentStateLook(entry.state).label,
            if (duration != null) formatSubagentDuration(duration),
          ].join(' · ');
    final result = entry?.finalResult;
    final childId = call.childId;
    return InkWell(
      key: ValueKey('delegation-child-${childId ?? call.title}'),
      onTap: childId == null ? null : () => _open(context, ref, childId),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.xl + Insets.md,
          Insets.xs,
          Insets.md,
          Insets.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              call.title ?? entry?.title ?? 'Child session',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              facts,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (result != null)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Text(
                  result,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref, String id) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final opened = await ref.read(explorerActionsProvider).openNative(id);
    final message = opened.message;
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
