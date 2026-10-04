import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/usage_chip.dart' show formatResetClock;
import '../application/session_queue_providers.dart';

/// The messages [sessionId] holds at the server, below the transcript: each
/// a bubble on the sender's side, marked queued, with Edit and Cancel while
/// it waits. A delivered one leaves here and shows in the transcript.
class QueuedMessagesStrip extends ConsumerWidget {
  const QueuedMessagesStrip({
    super.key,
    required this.sessionId,
    this.onBackToComposer,
  });

  final String sessionId;

  /// Puts a failed message's text back in the composer; null offers only
  /// Dismiss.
  final ValueChanged<String>? onBackToComposer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(sessionQueueProvider(sessionId));
    if (messages.isEmpty) return const SizedBox.shrink();
    final hold = queueHoldOf(messages);
    var place = 0;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hold != null)
            _HoldLine(sessionId: sessionId, hold: hold, messages: messages),
          for (final message in messages)
            _QueuedBubble(
              key: ValueKey('queued-${message.id}'),
              message: message,
              place: message.state == QueuedMessageState.failed
                  ? null
                  : ++place,
              onBackToComposer: onBackToComposer,
            ),
        ],
      ),
    );
  }
}

/// Why the queue waits past the turn's end, over its messages.
class _HoldLine extends ConsumerStatefulWidget {
  const _HoldLine({
    required this.sessionId,
    required this.hold,
    required this.messages,
  });

  final String sessionId;
  final QueueHold hold;
  final List<QueuedMessage> messages;

  @override
  ConsumerState<_HoldLine> createState() => _HoldLineState();
}

class _HoldLineState extends ConsumerState<_HoldLine> {
  /// Set while Send next or Resume now is on its way: a resume takes seconds.
  String? _pending;

  String get sessionId => widget.sessionId;
  QueueHold get hold => widget.hold;
  List<QueuedMessage> get messages => widget.messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.watch(clockProvider).nowUtc().toLocal();
    final caps = ref.watch(capabilitiesProvider);
    final controls = caps.sessionQueueControl;
    final pending = _pending;
    final actions = !controls
        ? const <Widget>[]
        : pending != null
        ? [
            TextButton(
              key: const ValueKey('queue-action-pending'),
              onPressed: null,
              child: Text(pending),
            ),
          ]
        : switch (hold.kind) {
            QueueHoldKind.paused => [
              TextButton(
                key: const ValueKey('queue-send-next'),
                onPressed: () => _sendNext(context),
                child: const Text('Send next'),
              ),
              TextButton(
                key: const ValueKey('queue-cancel-all'),
                onPressed: () => _cancelAll(context),
                child: const Text('Cancel all'),
              ),
            ],
            QueueHoldKind.stopped when caps.mayStart => [
              TextButton(
                key: const ValueKey('queue-resume-now'),
                onPressed: () => _sendNext(context, resuming: true),
                child: const Text('Resume now'),
              ),
            ],
            _ => const <Widget>[],
          };
    return Padding(
      key: const ValueKey('queue-hold'),
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                hold.kind == QueueHoldKind.paused
                    ? AppIcons.pause
                    : AppIcons.clock,
                size: Touch.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  queueHoldWords(hold, now),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: Insets.xs, children: actions),
            ),
        ],
      ),
    );
  }

  Future<void> _sendNext(BuildContext context, {bool resuming = false}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _pending = resuming ? 'Resuming…' : 'Sending…');
    try {
      await ref.read(sessionQueueActionsProvider).sendNext(sessionId);
    } on Object catch (error) {
      final what = resuming ? 'resume it' : 'send it';
      final why = error is DataRefused ? error.message : '$error';
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not $what: $why')),
      );
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  Future<void> _cancelAll(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(sessionQueueActionsProvider)
          .cancelAll(sessionId, messages);
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not cancel them all: ${refusal.message}'),
        ),
      );
    }
  }
}

class _QueuedBubble extends ConsumerWidget {
  const _QueuedBubble({
    super.key,
    required this.message,
    required this.place,
    this.onBackToComposer,
  });

  final QueuedMessage message;

  /// Its turn among the waiting messages, from 1; null for a failed one.
  final int? place;
  final ValueChanged<String>? onBackToComposer;

  static const _corners = BorderRadius.only(
    topLeft: Radius.circular(Radii.lg),
    topRight: Radius.circular(Radii.lg),
    bottomLeft: Radius.circular(Radii.lg),
    bottomRight: Radius.circular(Insets.xs),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = message.state == QueuedMessageState.failed;
    final label = switch (message.state) {
      QueuedMessageState.delivering => 'Sending…',
      QueuedMessageState.failed => 'Not sent',
      _ => place == 1 ? 'Queued · next' : 'Queued · $place',
    };
    final labelColor = failed ? scheme.error : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: LayoutBuilder(
        builder: (context, box) => Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: box.maxWidth * Chrome.chatBubbleShare,
            ),
            child: DecoratedBox(
              // Outlined, not filled: it has not reached the agent yet.
              decoration: BoxDecoration(
                borderRadius: _corners,
                border: Border.all(
                  color: failed ? scheme.error : scheme.outlineVariant,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Radii.lg,
                  Insets.sm,
                  Insets.sm,
                  Insets.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          failed ? AppIcons.warningCircle : AppIcons.clock,
                          size: Touch.iconSmall,
                          color: labelColor,
                        ),
                        const SizedBox(width: Insets.xs),
                        Text(
                          label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: labelColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Insets.xs),
                    _ClampedText(
                      key: ValueKey('queued-text-${message.id}'),
                      id: message.id,
                      text: message.text,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (failed && message.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: Insets.xs),
                        child: Text(
                          message.error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.error,
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: Insets.xs,
                        children: [
                          if (message.editable)
                            TextButton(
                              key: ValueKey('queued-edit-${message.id}'),
                              onPressed: () => _edit(context, ref),
                              child: const Text('Edit'),
                            ),
                          if (failed && onBackToComposer != null)
                            TextButton(
                              key: ValueKey('queued-back-${message.id}'),
                              onPressed: () => _backToComposer(context, ref),
                              child: const Text('Back to composer'),
                            ),
                          if (message.editable || failed)
                            TextButton(
                              key: ValueKey('queued-cancel-${message.id}'),
                              onPressed: () => _cancel(context, ref),
                              child: Text(failed ? 'Dismiss' : 'Cancel'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(sessionQueueActionsProvider)
          .cancel(message.sessionId, message.id);
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not cancel it: ${refusal.message}')),
      );
    }
  }

  /// The text goes back to the box, then the failed row is dismissed.
  Future<void> _backToComposer(BuildContext context, WidgetRef ref) async {
    onBackToComposer?.call(message.text);
    await _cancel(context, ref);
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final actions = ref.read(sessionQueueActionsProvider);
    final text = await showAdaptiveModal<String>(
      context: context,
      title: 'Edit queued message',
      builder: (context) => _EditQueuedBody(initial: message.text),
    );
    if (text == null || text == message.text) return;
    try {
      await actions.edit(message.sessionId, message.id, text);
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not edit it: ${refusal.message}')),
      );
    }
  }
}

/// A queued message's text, three lines at most until expanded: a long one
/// must not crowd the composer.
class _ClampedText extends StatefulWidget {
  const _ClampedText({
    super.key,
    required this.id,
    required this.text,
    required this.style,
  });

  static const maxLines = 3;

  final String id;
  final String text;
  final TextStyle? style;

  @override
  State<_ClampedText> createState() => _ClampedTextState();
}

class _ClampedTextState extends State<_ClampedText> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: _ClampedText.maxLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.text,
            style: widget.style,
            maxLines: _expanded ? null : _ClampedText.maxLines,
            overflow: _expanded ? null : TextOverflow.ellipsis,
          ),
          if (overflows)
            TextButton(
              key: ValueKey('queued-expand-${widget.id}'),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Show less' : 'Show more'),
            ),
        ],
      );
    },
  );
}

class _EditQueuedBody extends StatefulWidget {
  const _EditQueuedBody({required this.initial});

  final String initial;

  @override
  State<_EditQueuedBody> createState() => _EditQueuedBodyState();
}

class _EditQueuedBodyState extends State<_EditQueuedBody> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('queued-edit-field'),
          controller: _text,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: Insets.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('queued-edit-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: Insets.sm),
            // An empty message cannot be queued: Cancel the message instead.
            ValueListenableBuilder(
              valueListenable: _text,
              builder: (context, value, _) => FilledButton(
                key: const ValueKey('queued-edit-save'),
                onPressed: value.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_text.text),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// What holds [messages]' queue, as the server marks its queued ones; null
/// when nothing does, or the server is too old to say.
QueueHold? queueHoldOf(List<QueuedMessage> messages) {
  for (final message in messages) {
    if (message.state == QueuedMessageState.queued) return message.hold;
  }
  return null;
}

/// [hold] in words, its time on this machine's clock.
String queueHoldWords(QueueHold hold, DateTime now) {
  final until = hold.until;
  final at = until == null ? null : formatResetClock(until, now);
  return switch (hold.kind) {
    QueueHoldKind.limit when at != null => 'Held until the limit resets · $at',
    QueueHoldKind.limit => 'Held — the agent stopped on its usage limit',
    QueueHoldKind.scheduled when at != null =>
      'Held until the scheduled resume · $at',
    QueueHoldKind.scheduled => 'Held until the scheduled resume',
    QueueHoldKind.paused => 'Paused — nothing more goes until you say',
    QueueHoldKind.stopped => "Waiting — this session isn't running",
  };
}

/// The session bar's word on what waits — `2 queued`, `Paused · 2` — seen
/// from the terminal view too, where the strip is not. Nothing, and no width,
/// while nothing waits.
class QueuedCountChip extends ConsumerWidget {
  const QueuedCountChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(sessionQueueProvider(sessionId));
    final waiting = messages
        .where((m) => m.state != QueuedMessageState.failed)
        .length;
    final failed = messages.length - waiting;
    if (messages.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hold = queueHoldOf(messages);
    final now = ref.watch(clockProvider).nowUtc().toLocal();
    final label = switch (hold?.kind) {
      _ when waiting == 0 => '$failed not sent',
      QueueHoldKind.paused => 'Paused · $waiting',
      QueueHoldKind.stopped => 'Waiting · $waiting',
      QueueHoldKind.limit || QueueHoldKind.scheduled => 'Held · $waiting',
      null => '$waiting queued',
    };
    final tooltip = [
      waiting == 1 ? '1 message waits' : '$waiting messages wait',
      if (hold != null) queueHoldWords(hold, now),
      if (failed > 0 && waiting > 0) '$failed not sent',
    ].join(' · ');
    final color = waiting == 0 ? scheme.error : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          label: tooltip,
          excludeSemantics: true,
          child: Container(
            key: const ValueKey('queued-count'),
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hold?.kind == QueueHoldKind.paused
                      ? AppIcons.pause
                      : AppIcons.stack,
                  size: Chrome.iconSmall,
                  color: color,
                ),
                const SizedBox(width: Insets.xs),
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
