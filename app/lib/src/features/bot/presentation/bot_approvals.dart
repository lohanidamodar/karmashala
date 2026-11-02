import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../application/bot_providers.dart';

/// What a phone without the grant reads in place of the buttons.
const kBotApprovalNotGranted =
    'This phone was not granted approval rights. Answer from a client that '
    'was.';

/// The strip's share of the footer against the strips beside it, which take
/// one each: an equal share left the buttons out of sight.
const _footerShare = 6;

/// What the bot is waiting for a person to answer, over the box. Bounded, so
/// a few of them scroll here rather than push the box away.
class BotApprovalStrip extends ConsumerWidget {
  const BotApprovalStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final approvals = ref.watch(
      botStateProvider.select((s) => s?.approvals ?? const <BotApproval>[]),
    );
    if (approvals.isEmpty) return const SizedBox.shrink();
    return Flexible(
      flex: _footerShare,
      child: SingleChildScrollView(
        key: const ValueKey('bot-approvals'),
        primary: false,
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.xs,
          Insets.md,
          Insets.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final approval in approvals)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: BotApprovalCard(
                  key: ValueKey('bot-approval:${approval.id}'),
                  approval: approval,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One exact call the bot made that cannot be undone, in plain words, with
/// Yes and No. Yes runs that call and nothing else.
class BotApprovalCard extends ConsumerStatefulWidget {
  const BotApprovalCard({required this.approval, super.key});

  final BotApproval approval;

  @override
  ConsumerState<BotApprovalCard> createState() => _BotApprovalCardState();
}

class _BotApprovalCardState extends ConsumerState<BotApprovalCard> {
  var _answering = false;
  var _showCall = false;
  String? _refusal;

  Future<void> _answer({required bool approve}) async {
    setState(() {
      _answering = true;
      _refusal = null;
    });
    try {
      await ref
          .read(botActionsProvider)
          .answer(widget.approval.id, approve: approve);
    } on DataRefused catch (refusal) {
      if (mounted) setState(() => _refusal = refusal.message);
    } finally {
      if (mounted) setState(() => _answering = false);
    }
  }

  String get _call {
    final approval = widget.approval;
    final arguments = const JsonEncoder.withIndent(
      '  ',
    ).convert(approval.arguments);
    return '${approval.tool}\n$arguments';
  }

  @override
  Widget build(BuildContext context) {
    final approval = widget.approval;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mayApprove = ref.watch(
      capabilitiesProvider.select((c) => c.mayApprove),
    );
    final until = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(approval.expiresAt.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Semantics(
      container: true,
      label: 'Approval: ${approval.summary}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: SemanticColors.of(context).attention),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(approval.summary, style: theme.textTheme.bodyMedium),
              const SizedBox(height: Insets.xs),
              Text(
                'Nothing runs unless you say Yes. Expires at $until.',
                style: muted,
              ),
              if (_showCall) ...[
                const SizedBox(height: Insets.xs),
                SelectableText(
                  _call,
                  key: const ValueKey('bot-approval-call'),
                  style: muted?.copyWith(fontFamily: 'monospace'),
                ),
              ],
              if (_refusal case final refusal?) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  refusal,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
              const SizedBox(height: Insets.sm),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (mayApprove) ...[
                    Semantics(
                      label: 'Yes, ${approval.summary}',
                      excludeSemantics: true,
                      button: true,
                      child: FilledButton(
                        key: ValueKey('bot-approve:${approval.id}'),
                        onPressed: _answering
                            ? null
                            : () => _answer(approve: true),
                        child: const Text('Yes'),
                      ),
                    ),
                    Semantics(
                      label: 'No, do not ${approval.summary}',
                      excludeSemantics: true,
                      button: true,
                      child: OutlinedButton(
                        key: ValueKey('bot-deny:${approval.id}'),
                        onPressed: _answering
                            ? null
                            : () => _answer(approve: false),
                        child: const Text('No'),
                      ),
                    ),
                  ] else
                    Text(kBotApprovalNotGranted, style: muted),
                  TextButton(
                    key: ValueKey('bot-approval-show:${approval.id}'),
                    onPressed: () => setState(() => _showCall = !_showCall),
                    child: Text(_showCall ? 'Hide the call' : 'Show the call'),
                  ),
                  if (_answering) const InlineSpinner(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
