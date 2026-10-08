import '../../github/server_secret_requests.dart';
import 'server_tool_set.dart';

/// `request_secret`: an agent asks the owner for a secret, the owner sees a
/// private card in the agent's thread, and the agent gets back a single-use
/// reference to hand to a tool that takes one — never the value.
class SecretToolSet extends ServerToolSet {
  SecretToolSet(this.requests);

  final ServerSecretRequests requests;

  static const Duration _defaultWait = Duration(minutes: 10);
  static const Duration _longestWait = Duration(minutes: 30);

  @override
  List<Map<String, Object?>> get schemas => secretToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'request_secret' => runTool(() => _request(arguments, callerSessionId)),
    _ => null,
  };

  Future<Object?> _request(
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) async {
    if (callerSessionId == null || callerSessionId.isEmpty) {
      throw StateError(
        'request_secret shows a card in your own thread, and this caller is '
        'not running inside a session.',
      );
    }
    String required(String key) {
      final value = (arguments[key] as String?)?.trim();
      if (value == null || value.isEmpty) {
        throw ArgumentError('$key is needed.');
      }
      if (value.length > 500) throw ArgumentError('$key is too long.');
      return value;
    }

    final label = required('label');
    final reason = required('reason');
    final seconds = (arguments['timeoutSeconds'] as num?)?.round();
    final wait = seconds == null
        ? _defaultWait
        : Duration(seconds: seconds.clamp(30, _longestWait.inSeconds));
    final outcome = await requests.request(
      sessionId: callerSessionId,
      label: label,
      reason: reason,
      timeout: wait,
    );
    return switch (outcome) {
      SecretProvided(:final reference) => {
        'status': 'saved',
        'reference': reference,
        'note':
            'The owner saved it on the server. This reference works once: '
            'pass it where a tool asks for one (signingRef on '
            'webhook_create or automation_propose). You will not see the '
            'value.',
      },
      SecretDeclined() => {
        'status': 'declined',
        'note': 'The owner declined. Do not ask again for the same thing.',
      },
      SecretUnanswered() => {
        'status': 'unanswered',
        'note':
            'Nobody answered in ${wait.inMinutes} minutes; nothing was saved.',
      },
    };
  }
}

const List<Map<String, Object?>> secretToolSchemas = [
  {
    'name': 'request_secret',
    'description':
        'Ask the owner for a secret (a webhook signing secret, an API key). '
        'They see a private card in your thread with your label and reason, '
        'and either save it on the server or decline. You get back a '
        'single-use reference, never the value: pass it to a tool that takes '
        'one (signingRef). Blocks until they answer or the wait ends.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'label': {
          'type': 'string',
          'description': 'What the secret is: "Stripe webhook signing secret".',
        },
        'reason': {
          'type': 'string',
          'description': 'Why you need it, in a sentence the owner can judge.',
        },
        'timeoutSeconds': {
          'type': 'integer',
          'minimum': 30,
          'maximum': 1800,
          'description': 'How long to wait for an answer (default 600).',
        },
      },
      'required': ['label', 'reason'],
    },
  },
];
