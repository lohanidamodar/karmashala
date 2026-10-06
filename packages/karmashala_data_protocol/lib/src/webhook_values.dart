import 'package:karmashala_automations/webhooks.dart';

/// A webhook's signing secret, just made — the one time it leaves the server.
final class WebhookIssued {
  const WebhookIssued({
    required this.automationId,
    required this.hookId,
    required this.url,
    required this.secret,
  });

  final String automationId;
  final String hookId;

  /// Null while the server has no relay to take calls on.
  final String? url;
  final String secret;

  Map<String, Object?> toJson() => {
    'automationId': automationId,
    'hookId': hookId,
    'url': url,
    'secret': secret,
  };

  static WebhookIssued fromJson(Map<String, Object?> json) => WebhookIssued(
    automationId: json['automationId']! as String,
    hookId: json['hookId']! as String,
    url: json['url'] as String?,
    secret: json['secret']! as String,
  );

  @override
  String toString() => 'WebhookIssued($automationId)';
}

/// What a person sees of one webhook: where it is called, whether the server
/// is listening for it, and its recent calls. Never its secret.
final class WebhookStatus {
  const WebhookStatus({
    required this.url,
    required this.listening,
    required this.problem,
    required this.calls,
  });

  /// Null while the server has no relay to take calls on.
  final String? url;
  final bool listening;

  /// Why the server is not listening, in words; null when it is.
  final String? problem;

  /// Newest first.
  final List<WebhookCall> calls;

  Map<String, Object?> toJson() => {
    'url': url,
    'listening': listening,
    'problem': problem,
    'calls': [for (final call in calls) webhookCallToJson(call)],
  };

  static WebhookStatus fromJson(Map<String, Object?> json) => WebhookStatus(
    url: json['url'] as String?,
    listening: json['listening'] as bool? ?? false,
    problem: json['problem'] as String?,
    calls: [
      for (final item in json['calls'] as List? ?? const [])
        webhookCallFromJson((item as Map).cast<String, Object?>()),
    ],
  );
}
