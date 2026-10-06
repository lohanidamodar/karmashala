part of '../data_request.dart';

// Webhooks: a secret made, and what a person sees of one. The webhook itself
// is an automation, saved with `automations.save`.

DataRequest<Object?>? _webhooksRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      WebhookRotate.name => WebhookRotate(args.string('automationId')),
      WebhookStatusRead.name => WebhookStatusRead(
        args.string('automationId'),
        limit: args.optionalInt('limit') ?? 50,
      ),
      _ => null,
    };

/// Webhook work that writes the server's vault or reads its listener;
/// answered when done.
sealed class WebhooksWorkRequest<R> extends DataRequest<R> {
  const WebhooksWorkRequest();
}

/// Makes a new signing secret for webhook [automationId], replacing the old
/// one at once, and answers it — the only time it is ever sent.
final class WebhookRotate extends WebhooksWorkRequest<WebhookIssued> {
  const WebhookRotate(this.automationId);

  static const String name = 'webhooks.rotate';

  final String automationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'automationId': automationId};

  @override
  Object? resultToJson(WebhookIssued result) => result.toJson();

  @override
  WebhookIssued resultFromJson(Object? json) =>
      _decode(kind, () => WebhookIssued.fromJson(_object(json, kind)));
}

/// Webhook [automationId]'s URL, whether it is being listened for, and its
/// newest [limit] calls.
final class WebhookStatusRead extends WebhooksWorkRequest<WebhookStatus> {
  const WebhookStatusRead(this.automationId, {this.limit = 50});

  static const String name = 'webhooks.status';

  final String automationId;
  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'automationId': automationId,
    'limit': limit,
  };

  @override
  Object? resultToJson(WebhookStatus result) => result.toJson();

  @override
  WebhookStatus resultFromJson(Object? json) =>
      _decode(kind, () => WebhookStatus.fromJson(_object(json, kind)));
}
