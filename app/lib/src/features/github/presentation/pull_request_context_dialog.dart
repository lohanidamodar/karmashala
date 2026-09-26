import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/session_notice.dart';
import '../application/pull_request_context_service.dart';
import 'package:karmashala_git/pull_request_context.dart';

/// Attaches a pull request's context to a session, showing the exact text.
///
/// The preview is not a summary of what will be sent; it **is** what will be
/// sent, rendered by the one function that renders it. Ticking a part redraws
/// it, so nothing can be attached without having been readable first.
class PullRequestContextDialog extends ConsumerStatefulWidget {
  const PullRequestContextDialog({
    required this.sessionId,
    required this.source,
    super.key,
  });

  final String sessionId;
  final PullRequestContextSource source;

  /// Gathers the context and asks. Answers with whether anything was sent.
  static Future<bool> show(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) async {
    final source = await ref
        .read(pullRequestContextServiceProvider)
        .sourceFor(sessionId);
    if (!context.mounted) return false;
    if (source == null) {
      ref
          .read(sessionNoticesProvider.notifier)
          .post(
            sessionId,
            const SessionNotice(
              message:
                  'Karmashala has not read a pull request for this session, '
                  'so there is no context to attach.',
              tone: SessionNoticeTone.warning,
            ),
          );
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (_) =>
              PullRequestContextDialog(sessionId: sessionId, source: source),
        ) ??
        false;
  }

  @override
  ConsumerState<PullRequestContextDialog> createState() =>
      _PullRequestContextDialogState();
}

class _PullRequestContextDialogState
    extends ConsumerState<PullRequestContextDialog> {
  late final Set<PullRequestContextPart> _parts = {...widget.source.available};
  final _instruction = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _instruction.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  String get _prompt => buildPullRequestContext(
    source: widget.source,
    parts: _parts,
    instruction: _instruction.text,
  );

  Future<void> _send() async {
    if (_busy) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Captured before the await, so what is sent is exactly what was on screen.
    final prompt = _prompt;
    try {
      await ref
          .read(pullRequestContextServiceProvider)
          .send(
            sessionId: widget.sessionId,
            prompt: prompt,
            parts: _parts,
            pullRequestNumber: widget.source.snapshot.number,
          );
      navigator.pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(error is StateError ? error.message : '$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = widget.source.available;
    return AlertDialog(
      title: Text('Attach pull request #${widget.source.snapshot.number}'),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final part in available)
              CheckboxListTile(
                value: _parts.contains(part),
                onChanged: (on) => setState(
                  () => on ?? false ? _parts.add(part) : _parts.remove(part),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(part.label),
              ),
            // What was **not** offered, said rather than left as an absence:
            // a reader who sees no "Failing checks" box should know whether
            // that means none are failing or that nobody asked.
            if (available.length < PullRequestContextPart.values.length)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.sm),
                child: Text(
                  'Not offered, because this pull request has none: '
                  '${[for (final part in PullRequestContextPart.values)
                    if (!widget.source.has(part)) part.label.toLowerCase()].join(', ')}.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            TextField(
              controller: _instruction,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'What should the agent do with it?',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: Insets.md),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Exactly what will be sent',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  iconSize: Chrome.iconAction,
                  icon: const Icon(AppIcons.copy),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _prompt)),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Insets.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(_prompt, style: MonoStyles.small),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || _parts.isEmpty ? null : _send,
          child: const Text('Send to session'),
        ),
      ],
    );
  }
}

/// What was actually sent, read back out of the session's own record.
///
/// The half of this feature the transcript cannot give back: Claude Code
/// collapses a long paste to `[Pasted text #N]`, so without this nobody can
/// say afterwards what the agent was told.
class SentContextCardsDialog extends ConsumerWidget {
  const SentContextCardsDialog({required this.sessionId, super.key});

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) =>
      showDialog<void>(
        context: context,
        builder: (_) => SentContextCardsDialog(sessionId: sessionId),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cards =
        ref.watch(sentContextCardsProvider(sessionId)).value ??
        const <SentContextCard>[];
    return AlertDialog(
      title: const Text('Context sent to this session'),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: cards.isEmpty
            ? const Text('No pull request context has been attached here.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final card in cards)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        card.pullRequestNumber == null
                            ? 'Context'
                            : 'Pull request #${card.pullRequestNumber}',
                      ),
                      subtitle: Text(
                        '${_stamp(card.at)} · ${card.parts.join(', ')}',
                        style: theme.textTheme.bodySmall,
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(Insets.sm),
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: SelectableText(
                            card.prompt,
                            style: MonoStyles.small,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  static String _stamp(DateTime at) {
    final local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
