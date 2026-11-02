import 'dart:async';

import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentStatusReport;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart' show BotApproval;
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_input.dart';
import '../../sessions/application/session_status_providers.dart';

final _log = AppLogger.named('bot');

/// Why the bot could not be read, in words; null while nothing is wrong.
class BotReadFailure extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? words) {
    if (ref.mounted) state = words;
  }
}

final botReadFailureProvider = NotifierProvider<BotReadFailure, String?>(
  BotReadFailure.new,
);

/// **Keeps this client following the bot.** A link follows only after it asks
/// and must ask again after a reconnect, so this asks on every connection.
/// Following creates nothing: the row is made by the first message. Watched
/// by the shell, which is why the dot moves while the panel is shut.
final botFollowerProvider = Provider<void>((ref) {
  final client = ref.watch(dataClientProvider);
  if (!ref.watch(capabilitiesProvider.select((c) => c.bot))) return;
  void follow() => unawaited(
    client
        .send(const BotSubscribe())
        .then(
          (reply) {
            client.applyBot(reply.value);
            ref.read(botReadFailureProvider.notifier).set(null);
          },
          onError: (Object error) {
            _log.warning('Could not follow the bot: $error');
            ref
                .read(botReadFailureProvider.notifier)
                .set(error is DataRefused ? error.message : '$error');
          },
        ),
  );
  if (client.connection.state == DataLinkState.connected) follow();
  final changes = client.connectionChanges.listen((connection) {
    if (connection.state == DataLinkState.connected) follow();
  });
  ref.onDispose(changes.cancel);
});

/// The bot as this client last heard it; null until a link has followed it.
class BotStateNotifier extends Notifier<BotState?> {
  @override
  BotState? build() {
    final client = ref.watch(dataClientProvider);
    final changes = client.botChanges.listen((next) => state = next);
    ref.onDispose(changes.cancel);
    return client.bot;
  }
}

final botStateProvider = NotifierProvider<BotStateNotifier, BotState?>(
  BotStateNotifier.new,
);

/// The bot's row, null before the first message and after a clear.
final botSessionIdProvider = Provider<String?>(
  (ref) => ref.watch(botStateProvider.select((s) => s?.session?.id)),
);

/// Whether a turn holds the bot: Clear and the switcher wait for it.
final botTurnRunningProvider = Provider<bool>((ref) {
  final id = ref.watch(botSessionIdProvider);
  if (id == null) return false;
  return switch (ref
      .watch(agentSessionStatusProvider(id))
      .asData
      ?.value
      .turnStatus) {
    AgentActivityStatus.working || AgentActivityStatus.awaitingApproval => true,
    _ => false,
  };
});

/// Whether the panel is up. A provider, not widget state, so it stays open
/// across navigation and across a window crossing 600 px.
class BotPanel extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;
  void close() => state = false;
  void toggle() => state = !state;
}

final botPanelProvider = NotifierProvider<BotPanel, bool>(BotPanel.new);

/// Whether the first message is on its way: the box it was typed in stays up
/// until it has gone, and keeps the words if it does not.
class BotFirstSend extends Notifier<bool> {
  @override
  bool build() => false;

  void set({required bool sending}) {
    if (ref.mounted) state = sending;
  }
}

final botFirstSendProvider = NotifierProvider<BotFirstSend, bool>(
  BotFirstSend.new,
);

/// What the person does to the bot.
class BotActions {
  BotActions(this._ref);

  final Ref _ref;

  /// The words last sent and not yet taken, and the key that makes a retry of
  /// them the same request to the server.
  String? _keyedText;
  String? _sendKey;

  DataClient get _client => _ref.read(dataClientProvider);

  Future<BotState> _ask(BotRequest<BotState> request) => _client.write(
    request,
    domain: DataDomain.sessions,
    apply: (state, _) => _client.applyBot(state),
  );

  /// The first message: asks for the row, which the server makes now and not
  /// before, then sends as any session does. A bot it stopped resumes at the
  /// server; while an expiry notice waits the message shows as queued for a
  /// moment, which is delivery and not a failure.
  Future<void> sendFirst(String text) async {
    if (text != _keyedText) {
      _keyedText = text;
      _sendKey = newSessionInputId();
    }
    final first = _ref.read(botFirstSendProvider.notifier)..set(sending: true);
    try {
      final state = await _ask(const BotOpen());
      final id = state.session?.id;
      if (id == null) {
        throw StateError('The server did not start the bot. Try again.');
      }
      await _ref
          .read(sessionActionsProvider)
          .continueInBackground(id, text, requestId: _sendKey);
      _keyedText = null;
      _sendKey = null;
    } on DataRefused catch (refusal) {
      throw StateError(refusal.message);
    } finally {
      first.set(sending: false);
    }
  }

  /// Saves [agentId], null for "Default agent", and switches a row that
  /// exists: one call, so a switch can never land without its save.
  Future<void> setAgent(String? agentId) => _ask(BotAgentSet(agentId));

  /// Clear conversation. The person has been asked.
  Future<void> clear() => _ask(const BotClear());

  /// A person's Yes or No.
  Future<void> answer(String id, {required bool approve}) =>
      _client.write<BotApproval>(
        BotApprovalAnswer(id, approve: approve),
        domain: DataDomain.sessions,
        apply: (approval, _) => _client.applyBotApproval(approval),
      );
}

final botActionsProvider = Provider<BotActions>(BotActions.new);

/// A reply came while the panel was shut. Cleared by opening it.
class BotUnread extends Notifier<bool> {
  @override
  bool build() {
    final id = ref.watch(botSessionIdProvider);
    ref.listen(botPanelProvider, (_, open) {
      if (open) state = false;
    });
    if (id == null) return false;
    ref.listen(agentSessionStatusProvider(id), (was, now) {
      final ended =
          _working(was?.asData?.value) && !_working(now.asData?.value);
      if (ended && !ref.read(botPanelProvider)) state = true;
    });
    return false;
  }

  static bool _working(AgentStatusReport? report) =>
      report?.turnStatus == AgentActivityStatus.working;
}

final botUnreadProvider = NotifierProvider<BotUnread, bool>(BotUnread.new);

/// What the Bot button's dot says.
enum BotAttention {
  none,

  /// A reply nobody has read here.
  unread,

  /// A question or an approval is waiting for the person.
  waiting,
}

final botAttentionProvider = Provider<BotAttention>((ref) {
  final state = ref.watch(botStateProvider);
  if (state == null) return BotAttention.none;
  if (state.approvals.isNotEmpty) return BotAttention.waiting;
  final id = state.session?.id;
  if (id != null) {
    final report = ref.watch(agentSessionStatusProvider(id)).asData?.value;
    if (report?.hasOpenPrompt == true || report?.hasOpenQuestion == true) {
      return BotAttention.waiting;
    }
  }
  if (ref.watch(botPanelProvider)) return BotAttention.none;
  final bots = ref.read(dataClientProvider).botIds;
  final unseen = ref
      .watch(attentionInboxProvider)
      .pending
      .any((item) => bots.contains(item.session.openId));
  return unseen || ref.watch(botUnreadProvider)
      ? BotAttention.unread
      : BotAttention.none;
});
