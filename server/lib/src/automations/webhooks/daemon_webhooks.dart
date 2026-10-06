import 'dart:async';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_relay/karmashala_relay.dart' show hooksListenIdOf;
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:karmashala_remote/remote.dart' show Backoff;
import 'package:karmashala_store/database.dart';

import '../../data/webhooks_work.dart';
import '../../domain/uuid.dart';
import 'hooks_relay_listener.dart';
import 'server_hook_vault.dart';
import 'webhook_call_handler.dart';

/// Webhooks in the server: the listener on its relay while any webhook is
/// enabled, the answer to each call, and the secrets a person rotates.
class DaemonWebhooks implements WebhooksWork {
  DaemonWebhooks({
    required AppDatabase database,
    required ServerHookVault vault,
    required WebhookLaunch launch,
    required bool Function(Automation automation) busy,
    required Uri? Function() relay,
    required void Function(List<DataChange> changes) tell,
    DateTime Function()? clock,
    String Function()? newId,
    Backoff Function()? backoff,
    void Function(String message)? log,
  }) : _automations = AutomationDao(database),
       _calls = WebhookCallDao(database),
       _vault = vault,
       _relay = relay,
       _log = log {
    handler = WebhookCallHandler(
      automations: _automations,
      calls: _calls,
      secretOf: vault.secretOf,
      launch: launch,
      busy: busy,
      now: clock ?? () => DateTime.now().toUtc(),
      newId: newId ?? newUuid,
      onRecorded: (call) => tell([WebhookCallRecorded(call)]),
      log: log,
    );
    _listener = HooksRelayListener(
      answer: handler.answer,
      backoff: backoff,
      log: log,
    );
  }

  final AutomationDao _automations;
  final WebhookCallDao _calls;
  final ServerHookVault _vault;
  final Uri? Function() _relay;
  final void Function(String message)? _log;
  late final WebhookCallHandler handler;
  late final HooksRelayListener _listener;
  var _closed = false;
  Future<void> _reconciling = Future<void>.value();

  bool get listening => _listener.state == HooksListenerState.listening;

  /// Listens while at least one webhook is enabled and there is a relay, and
  /// forgets the secrets of webhooks that are gone. Told after every write.
  void reconcile() {
    _reconciling = _reconciling
        .then((_) => _reconcile())
        .catchError((Object error) => _log?.call('webhooks: $error'));
  }

  Future<void> _reconcile() async {
    if (_closed) return;
    final all = _automations.webhooks();
    final relay = _relay();
    final wanted =
        relay != null &&
        all.any((a) => a.enabled && (a.webhook?.hookId.isNotEmpty ?? false));
    _listener.listenOn(
      wanted ? relay : null,
      wanted ? await _vault.listenKey() : null,
    );
    final kept = {for (final a in all) a.webhook!.hookId};
    for (final hookId in _vault.hookIds.where((id) => !kept.contains(id))) {
      await _vault.forget(hookId);
    }
  }

  Automation _webhook(String automationId) {
    final automation = _automations.getById(automationId);
    if (automation == null || !automation.isWebhook) {
      throw DataRefused.notFound('no webhook with id $automationId');
    }
    return automation;
  }

  /// Where [hookId] is called: the relay's https (or http) address, keeping a
  /// self-hoster's prefix. Null while there is no relay.
  Future<String?> _urlFor(String hookId) async {
    final relay = _relay();
    if (relay == null) return null;
    final listenId = hooksListenIdOf(await _vault.listenKey());
    return relay
        .replace(
          scheme: relay.scheme == 'wss' ? 'https' : 'http',
          path: joinRelayPath(relay.path, hookCallPath(listenId, hookId)),
          query: null,
        )
        .toString();
  }

  @override
  Future<WebhookIssued> rotate(String automationId) async {
    final automation = _webhook(automationId);
    final hookId = automation.webhook!.hookId;
    final secret = await _vault.rotate(hookId);
    reconcile();
    return WebhookIssued(
      automationId: automationId,
      hookId: hookId,
      url: await _urlFor(hookId),
      secret: secret,
    );
  }

  @override
  Future<WebhookStatus> status(String automationId, {int limit = 50}) async {
    final automation = _webhook(automationId);
    return WebhookStatus(
      url: await _urlFor(automation.webhook!.hookId),
      listening: listening,
      problem: listening
          ? null
          : _relay() == null
          ? 'This server has no relay to take calls on.'
          : _listener.problem ?? 'Not listening: no webhook is enabled.',
      calls: _calls.forAutomation(automationId, limit: limit.clamp(1, 200)),
    );
  }

  Future<void> close() async {
    _closed = true;
    await _reconciling;
    await _listener.close();
  }
}
