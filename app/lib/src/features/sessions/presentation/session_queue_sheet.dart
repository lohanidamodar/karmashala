import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../media/application/session_media_providers.dart';
import '../application/session_queue_providers.dart';
import 'queued_messages_strip.dart';
import 'transcript_image_preview.dart';

/// Opens [sessionId]'s queue: a sheet on a phone, a dialog on a desktop.
Future<void> showSessionQueue(BuildContext context, String sessionId) =>
    showAdaptiveModal<void>(
      context: context,
      title: 'Queued messages',
      builder: (context) => SessionQueuePanel(sessionId: sessionId),
    );

/// **Every message [sessionId] holds waiting, in the order they go**, each
/// with View, Edit, Remove and Send now, and the whole queue sent at once or
/// paused. The way in from the terminal view, which has no strip.
class SessionQueuePanel extends ConsumerStatefulWidget {
  const SessionQueuePanel({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionQueuePanel> createState() => _SessionQueuePanelState();
}

class _SessionQueuePanelState extends ConsumerState<SessionQueuePanel> {
  /// What is on its way, in words, while a send or a pause is.
  String? _pending;

  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final messages = ref.watch(sessionQueueProvider(sessionId));
    final manage = ref.watch(
      capabilitiesProvider.select((c) => c.sessionQueueManage),
    );
    final now = ref.watch(clockProvider).nowUtc().toLocal();
    if (messages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Text('Nothing waits in this queue.', style: muted),
      );
    }
    final hold = queueHoldOf(messages);
    final waiting = messages
        .where((m) => m.state == QueuedMessageState.queued)
        .length;
    final paused = hold?.kind == QueueHoldKind.paused;
    final idle = _pending == null;
    var place = 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (waiting > 0) Text(queuedWhenWords(hold, now), style: muted),
          if (manage)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.xs,
                children: [
                  FilledButton.tonal(
                    key: const ValueKey('queue-send-all'),
                    onPressed: idle && waiting > 0
                        ? () => _run(
                            'Sending…',
                            'send them',
                            (a) => a.sendAll(sessionId),
                          )
                        : null,
                    child: Text(waiting > 1 ? 'Send all now' : 'Send now'),
                  ),
                  OutlinedButton.icon(
                    key: ValueKey(paused ? 'queue-resume' : 'queue-pause'),
                    onPressed: idle && waiting > 0
                        ? () => _run(
                            paused ? 'Resuming…' : 'Pausing…',
                            paused ? 'resume it' : 'pause it',
                            (a) => a.setPaused(sessionId, paused: !paused),
                          )
                        : null,
                    icon: Icon(
                      paused ? AppIcons.play : AppIcons.pause,
                      size: Touch.iconSmall,
                    ),
                    label: Text(paused ? 'Resume' : 'Pause'),
                  ),
                  if (_pending case final pending?)
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: Text(pending, style: muted),
                    ),
                ],
              ),
            ),
          for (final message in messages)
            _QueueRow(
              key: ValueKey('queue-row-${message.id}'),
              message: message,
              place: message.state == QueuedMessageState.failed
                  ? null
                  : ++place,
              now: now,
              onSendNow: manage && idle
                  ? () => _run(
                      'Sending…',
                      'send it',
                      (a) => a.sendNow(sessionId, message.id),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _run(
    String doing,
    String what,
    Future<void> Function(SessionQueueActions actions) act,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _pending = doing);
    try {
      await act(ref.read(sessionQueueActionsProvider));
    } on Object catch (error) {
      final why = error is DataRefused ? error.message : '$error';
      messenger?.showSnackBar(SnackBar(content: Text('Could not $what: $why')));
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }
}

class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    super.key,
    required this.message,
    required this.place,
    required this.now,
    required this.onSendNow,
  });

  final QueuedMessage message;

  /// Its turn among the waiting messages, from 1; null for a failed one.
  final int? place;
  final DateTime now;
  final VoidCallback? onSendNow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final failed = message.state == QueuedMessageState.failed;
    final queued = message.state == QueuedMessageState.queued;
    final split = splitAttachedImages(message.text);
    final label = switch (message.state) {
      QueuedMessageState.delivering => 'Sending…',
      QueuedMessageState.failed => 'Not sent',
      _ => place == 1 ? 'Next' : 'Queued · $place',
    };
    final id = message.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: failed ? scheme.error : scheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.sm,
            Insets.sm,
            Insets.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: muted?.copyWith(color: failed ? scheme.error : null),
              ),
              if (queued)
                Text(queuedWhenWords(message.hold, now), style: muted),
              if (failed && message.error != null)
                Text(
                  message.error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              const SizedBox(height: Insets.xs),
              if (split.text.isNotEmpty)
                Text(
                  split.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              if (split.images.isNotEmpty)
                Row(
                  children: [
                    Icon(
                      AppIcons.image,
                      size: Touch.iconSmall,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Insets.xs),
                    Text(
                      split.images.length == 1
                          ? '1 image'
                          : '${split.images.length} images',
                      style: muted,
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: Insets.xs,
                  children: [
                    TextButton(
                      key: ValueKey('queue-view-$id'),
                      onPressed: () => _view(context),
                      child: const Text('View'),
                    ),
                    if (message.editable)
                      TextButton(
                        key: ValueKey('queue-edit-$id'),
                        onPressed: () =>
                            editQueuedMessage(context, ref, message),
                        child: const Text('Edit'),
                      ),
                    if (message.editable || failed)
                      TextButton(
                        key: ValueKey('queue-remove-$id'),
                        onPressed: () =>
                            cancelQueuedMessage(context, ref, message),
                        child: Text(failed ? 'Dismiss' : 'Remove'),
                      ),
                    if (queued && onSendNow != null)
                      TextButton(
                        key: ValueKey('queue-send-now-$id'),
                        onPressed: onSendNow,
                        child: const Text('Send now'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _view(BuildContext context) => showAdaptiveModal<void>(
    context: context,
    title: 'Queued message',
    builder: (context) => _QueuedMessageView(message: message),
  );
}

/// One queued message whole: its text, selectable, and every image it
/// carries, brought from the server when it is elsewhere.
class _QueuedMessageView extends ConsumerWidget {
  const _QueuedMessageView({required this.message});

  final QueuedMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final split = splitAttachedImages(message.text);
    return TranscriptImageSource(
      fetch: ref.watch(sessionImageFetchProvider(message.sessionId)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (split.text.isNotEmpty)
              SelectableText(
                split.text,
                key: const ValueKey('queue-view-text'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            for (final path in split.images)
              Padding(
                padding: const EdgeInsets.only(top: Insets.sm),
                child: TranscriptImagePreview(path: path),
              ),
          ],
        ),
      ),
    );
  }
}
