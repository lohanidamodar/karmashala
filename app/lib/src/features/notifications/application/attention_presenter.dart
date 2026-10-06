import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';

/// This window's half of attention (slice 5c): the server decides what is
/// news — a turn finished, a prompt opened, a turn failed — and tells it
/// ([AttentionNewsTold]); whether it interrupts the person here is this
/// window's to judge, against its own focus, what it shows and the person's
/// settings. Nothing is computed about any session here.
class AttentionPresenter {
  AttentionPresenter({
    required this.news,
    required this.readSettings,
    required this.isWindowFocused,
    required this.visibleSessionIds,
    required this.onNotify,
    this.onQuiet,
    this.policy = const AgentNotificationPolicy(),
  });

  final Stream<AttentionChange> news;
  final NotificationSettings Function() readSettings;
  final bool Function() isWindowFocused;
  final Set<String> Function() visibleSessionIds;
  final void Function(PendingNotification event) onNotify;

  /// News the person's level logs quietly, for a client with somewhere quiet
  /// to show it (a phone's shade). Null on a desktop: the inbox has it.
  final void Function(PendingNotification event)? onQuiet;
  final AgentNotificationPolicy policy;

  StreamSubscription<AttentionChange>? _subscription;

  /// Begins presenting. Idempotent.
  void start() {
    _subscription ??= news.listen((change) {
      if (change is AttentionNewsTold) present(change.news);
    });
  }

  /// One piece of news: a toast when the policy says so here, or a quiet one
  /// where the person's level logs it quietly.
  void present(AttentionNews news) {
    final decision = policy.decide(
      NotificationContext(
        transition: news.transition,
        settings: readSettings(),
        windowFocused: isWindowFocused(),
        visibleSessionIds: visibleSessionIds(),
      ),
    );
    if (decision.shouldNotify) return onNotify(news.pending);
    if (decision.quietReason != null) onQuiet?.call(news.pending.quietly());
  }

  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
