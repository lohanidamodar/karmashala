import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers a client's webhook requests: the server's webhooks, set once
/// `serve` has started them.
abstract interface class WebhooksWork {
  /// A new signing secret for [automationId]'s webhook, made and answered once.
  Future<WebhookIssued> rotate(String automationId);

  /// Makes [secret] [automationId]'s signing secret: one the owner gave in
  /// answer to an agent's request, which the agent never saw.
  Future<void> adoptSecret(String automationId, String secret);

  /// [automationId]'s URL, whether it is listened for, and its newest calls.
  Future<WebhookStatus> status(String automationId, {int limit});
}
