import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../application/decision_recorder.dart';
import '../application/session_decision_providers.dart';
import '../application/session_ui_providers.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/resume.dart' show describeAge;

/// Which session's decision record the panel is describing: the session **on
/// screen**, not the one last clicked in the Explorer.
final decisionsPanelSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(activePaneSessionIdProvider) ??
      ref.watch(selectedSessionIdProvider),
);

/// **What this session has settled**, in the words it was settled in. Empty is
/// "not recorded", never "nothing was decided"; a reversal is a new row.
class DecisionRecordPanel extends ConsumerWidget {
  const DecisionRecordPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(decisionsPanelSessionIdProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.stack,
          title: 'Decisions',
          actions: [
            IconButton(
              tooltip: 'Record a decision',
              icon: const Icon(AppIcons.plusCircle, size: Chrome.iconAction),
              onPressed: sessionId == null
                  ? null
                  : () => recordDecisionDialog(context, ref, sessionId),
            ),
          ],
        ),
        Expanded(child: _Body(sessionId: sessionId)),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = sessionId;
    if (id == null) {
      return const PanePlaceholder(
        message: 'Open a session to read what it has decided.',
        icon: AppIcons.stack,
      );
    }

    final decisions = ref.watch(sessionDecisionsProvider(id));
    if (decisions.isEmpty) {
      return const PanePlaceholder(
        icon: AppIcons.stack,
        // The packet's own wording, because the two readers need the same
        // warning: an empty record means nobody wrote anything down.
        message:
            'Not recorded: nothing has been written to this session’s '
            'decision record.\n\n'
            'That is not the same as “nothing was decided”. The record is '
            'written only by explicit acts — an approval answered, a '
            'verification finished, a checkpoint labelled, an agent recording '
            'one, or you writing one down here.',
      );
    }

    final now = ref.watch(clockProvider).nowUtc();
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      itemCount: decisions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) =>
          _DecisionRow(decision: decisions[index], now: now),
    );
  }
}

/// One decision: its heading, its own words, and who settled it when.
class _DecisionRow extends StatelessWidget {
  const _DecisionRow({required this.decision, required this.now});

  final DecisionRecord decision;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    // The heading colour separates a rule that binds the work from an approach
    // that was abandoned, which is the distinction a reader scans for.
    final colour = switch (decision.kind) {
      DecisionKind.approachRejected => semantic.attention,
      DecisionKind.approvalGranted ||
      DecisionKind.verificationVerdict => semantic.idle,
      DecisionKind.constraintAccepted ||
      DecisionKind.checkpointMarked => semantic.working,
      DecisionKind.unrecognised => semantic.neutral,
    };
    final detail = decision.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#${decision.sequence}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  decision.kind.label,
                  style: theme.textTheme.labelMedium?.copyWith(color: colour),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // Verbatim, and selectable: these are somebody's exact words and the
          // reason to be here is often to paste one somewhere else.
          SelectableText(
            decision.summary,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
          ),
          if (detail != null && detail.trim().isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            SelectableText(
              detail.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: Insets.xs),
          Text(
            _attribution(decision, now),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Who, when and from what — each part saying "not recorded" rather than
  /// disappearing, which would read as an unattributed fact.
  static String _attribution(DecisionRecord decision, DateTime now) {
    final origin = decision.originId == null
        ? decision.origin.label
        : '${decision.origin.label} `${decision.originId}`';
    return '${decision.decidedBy ?? 'Decided by: not recorded'}'
        ' · ${describeAge(now.difference(decision.recordedAt))}'
        ' · from $origin';
  }
}

/// The kinds a person may write here, and nothing else: a verdict with no run
/// behind it names a record that does not exist. An approval is theirs to give.
const List<DecisionKind> kHandWritableKinds = <DecisionKind>[
  DecisionKind.constraintAccepted,
  DecisionKind.approachRejected,
  DecisionKind.approvalGranted,
];

/// Asks for a decision and appends it through [DecisionRecorder] — the same
/// recorder every other act uses, so the row is indistinguishable but for it.
Future<void> recordDecisionDialog(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final entry = await showDialog<_DecisionEntry>(
    context: context,
    builder: (context) => const _RecordDecisionDialog(),
  );
  if (entry == null) return;
  ref
      .read(decisionRecorderProvider)
      .recordByHand(
        sessionId: sessionId,
        kind: entry.kind,
        summary: entry.summary,
        detail: entry.detail,
      );
}

class _DecisionEntry {
  const _DecisionEntry({
    required this.kind,
    required this.summary,
    this.detail,
  });

  final DecisionKind kind;
  final String summary;
  final String? detail;
}

class _RecordDecisionDialog extends StatefulWidget {
  const _RecordDecisionDialog();

  @override
  State<_RecordDecisionDialog> createState() => _RecordDecisionDialogState();
}

class _RecordDecisionDialogState extends State<_RecordDecisionDialog> {
  final _summary = TextEditingController();
  final _detail = TextEditingController();
  DecisionKind _kind = DecisionKind.constraintAccepted;

  @override
  void dispose() {
    _summary.dispose();
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSave = _summary.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Record a decision'),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<DecisionKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [
                for (final kind in kHandWritableKinds)
                  DropdownMenuItem(value: kind, child: Text(kind.label)),
              ],
              onChanged: (kind) => setState(
                () => _kind = kind ?? DecisionKind.constraintAccepted,
              ),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _summary,
              autofocus: true,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: 'What was decided',
                // Said here rather than after the fact: the record stores these
                // words exactly and never summarises them.
                helperText: 'Stored verbatim. Include the reason.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _detail,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'More of the same words (optional)',
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Append-only: this cannot be edited or removed. Recording a '
              'reversal later leaves this one standing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled rather than silently refused: the recorder drops a blank
          // summary, and a button that appeared to work would hide that.
          onPressed: canSave
              ? () => Navigator.of(context).pop(
                  _DecisionEntry(
                    kind: _kind,
                    summary: _summary.text,
                    detail: _detail.text.trim().isEmpty
                        ? null
                        : _detail.text.trim(),
                  ),
                )
              : null,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
