import 'dart:convert';

import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';

/// Starts [automation] — its prompt already filled — as one gated run, and
/// answers the run as it was left.
typedef WebhookLaunch =
    Future<AutomationRun> Function(Automation automation, String note);

/// Answers one call the relay forwarded. The payload is untrusted: the hook
/// is found and its signature, replay window and limit checked before the
/// body is parsed, and the caller learns only a status and a word — the
/// reason stays in the owner's log.
class WebhookCallHandler {
  WebhookCallHandler({
    required AutomationDao automations,
    required WebhookCallDao calls,
    required String? Function(String hookId) secretOf,
    required WebhookLaunch launch,
    required bool Function(Automation automation) busy,
    required DateTime Function() now,
    required String Function() newId,
    void Function(WebhookCall call)? onRecorded,
    void Function(String message)? log,
  }) : _automations = automations,
       _calls = calls,
       _secretOf = secretOf,
       _launch = launch,
       _busy = busy,
       _now = now,
       _newId = newId,
       _onRecorded = onRecorded,
       _log = log;

  final AutomationDao _automations;
  final WebhookCallDao _calls;
  final String? Function(String hookId) _secretOf;
  final WebhookLaunch _launch;
  final bool Function(Automation automation) _busy;
  final DateTime Function() _now;
  final String Function() _newId;
  final void Function(WebhookCall call)? _onRecorded;
  final void Function(String message)? _log;

  Future<HookAnswer> answer(HookCall call) async {
    final at = _now();
    final id = _newId();
    final delivery = webhookDeliveryId(call.headers);

    HookAnswer reply(
      Automation? automation,
      int status,
      String outcome, {
      String? reason,
      Map<String, Object?>? body,
      AutomationRun? run,
    }) {
      final recorded = WebhookCall(
        id: id,
        automationId: automation?.id,
        hookId: call.hookId,
        receivedAt: at,
        ip: call.ip,
        status: status,
        outcome: outcome,
        reason: reason,
        deliveryId: delivery,
        bodyHash: webhookBodyHash(call.body),
        bodyBytes: call.body.length,
        sessionId: run?.sessionId,
        runId: run?.id,
      );
      _calls
        ..insert(recorded)
        ..prune(call.hookId);
      if (automation != null) _onRecorded?.call(recorded);
      _log?.call(
        'webhooks: a call to ${automation == null ? 'an unknown hook' : '"${automation.name}"'} '
        'was answered $status ($outcome)',
      );
      return HookAnswer(
        id: call.id,
        status: status,
        body: body ?? {'error': outcome},
      );
    }

    final automation = _automations.byHookId(call.hookId);
    // One answer for both, so a caller cannot tell a hook that exists.
    if (automation == null || !automation.enabled || !automation.isWebhook) {
      return reply(
        automation,
        HookStatus.notFound,
        'not found',
        reason: automation == null ? null : 'This webhook is disabled.',
        body: const {'error': 'not found'},
      );
    }
    final webhook = automation.webhook!;
    if (call.method != 'POST') {
      return reply(
        automation,
        HookStatus.methodNotAllowed,
        'method not allowed',
      );
    }

    if (webhook.requireSignature) {
      final verdict = verifyWebhookSignature(
        secret: _secretOf(call.hookId) ?? '',
        headers: call.headers,
        body: call.body,
        now: at,
      );
      if (verdict != WebhookSignature.valid) {
        return reply(
          automation,
          HookStatus.badSignature,
          'bad signature',
          reason: switch (verdict) {
            WebhookSignature.missing => 'The call carried no signature.',
            WebhookSignature.stale =>
              'The X-Karmashala-Timestamp was more than '
                  '${kWebhookTimestampWindow.inMinutes} minutes from this '
                  'server\'s clock.',
            _ => 'The signature did not match this webhook\'s secret.',
          },
        );
      }
    }

    if (delivery != null &&
        _calls.deliverySeen(
          call.hookId,
          delivery,
          since: at.subtract(kWebhookReplayWindow),
        )) {
      return reply(
        automation,
        HookStatus.replay,
        'replay',
        reason: 'Delivery "$delivery" was already accepted.',
      );
    }

    final hour = at.subtract(const Duration(hours: 1));
    if (_calls.acceptedSince(automation.id, hour) >= webhook.callsPerHour) {
      return reply(
        automation,
        HookStatus.slowDown,
        'slow down',
        reason: 'Over ${webhook.callsPerHour} accepted calls in an hour.',
      );
    }
    if (!webhook.worktree && _busy(automation)) {
      return reply(
        automation,
        HookStatus.slowDown,
        'busy',
        reason:
            'Another run holds this checkout, and this webhook does not '
            'start in a worktree of its own.',
      );
    }

    final Object? payload;
    try {
      payload = call.body.isEmpty
          ? const <String, Object?>{}
          : jsonDecode(utf8.decode(call.body));
    } on FormatException {
      return reply(
        automation,
        HookStatus.badPayload,
        'bad payload',
        reason: 'The body is not UTF-8 JSON.',
      );
    }
    final WebhookFill fill;
    try {
      fill = fillWebhookTemplate(automation.prompt, payload);
    } on WebhookTemplateException catch (error) {
      return reply(
        automation,
        HookStatus.badPayload,
        'bad payload',
        reason: error.message,
      );
    }

    try {
      final run = await _launch(
        automation.copyWith(prompt: fill.prompt),
        'Started by a webhook call${delivery == null ? '' : ' ($delivery)'}.',
      );
      if (run.sessionId == null) {
        return reply(
          automation,
          HookStatus.failed,
          'not started',
          reason: run.reason,
          run: run,
          body: {'error': 'not started', 'id': id},
        );
      }
      return reply(
        automation,
        HookStatus.accepted,
        'accepted',
        run: run,
        body: {'session': run.sessionId, 'run': run.id},
      );
    } on Object catch (error) {
      return reply(
        automation,
        HookStatus.failed,
        'failed',
        reason: '$error',
        body: {'error': 'failed', 'id': id},
      );
    }
  }
}
