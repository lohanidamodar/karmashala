import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';

import '../../data/webhooks_work.dart';
import 'server_tool_set.dart';

/// `webhook_list` and `webhook_create`: an agent sees the webhooks armed here
/// and, under the person's operator grant, arms one. A secret is answered
/// only by the create that made it, and an agent can never arm one that
/// bypasses permissions — that is the owner's choice, in the app.
class WebhookToolSet extends ServerToolSet {
  WebhookToolSet({
    required Automation Function(Automation automation) save,
    required List<Automation> Function() webhooks,
    required WebhooksWork? Function() work,
    required AgentPermissionSupport? Function(String installationId)
    permissionsOf,
    required DateTime Function() now,
    required String Function() newId,
  }) : _save = save,
       _webhooks = webhooks,
       _work = work,
       _permissionsOf = permissionsOf,
       _now = now,
       _newId = newId;

  final Automation Function(Automation automation) _save;
  final List<Automation> Function() _webhooks;
  final WebhooksWork? Function() _work;
  final AgentPermissionSupport? Function(String installationId) _permissionsOf;
  final DateTime Function() _now;
  final String Function() _newId;

  @override
  List<Map<String, Object?>> get schemas => webhookToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'webhook_list' => runTool(_list),
    'webhook_create' => runTool(() => _create(arguments)),
    _ => null,
  };

  WebhooksWork get _webhooksWork =>
      _work() ?? (throw StateError('This server takes no webhook calls.'));

  Future<Object?> _list() async => {
    'webhooks': [
      for (final automation in _webhooks())
        {
          'id': automation.id,
          'name': automation.name,
          'enabled': automation.enabled,
          'repositoryId': automation.repositoryId,
          'agentInstallationId': automation.agentInstallationId,
          'permissionMode': automation.permissionMode?.canonical,
          'modelId': automation.modelId,
          'worktree': automation.worktree,
          'signatureRequired': automation.webhook!.requireSignature,
          'callsPerHour': automation.webhook!.callsPerHour,
          'template': automation.prompt,
          'url': (await _webhooksWork.status(automation.id, limit: 1)).url,
        },
    ],
  };

  Future<Object?> _create(Map<String, dynamic> arguments) async {
    String required(String key) {
      final value = (arguments[key] as String?)?.trim();
      if (value == null || value.isEmpty) {
        throw ArgumentError('$key is needed.');
      }
      return value;
    }

    final installationId = required('agentInstallationId');
    final support = _permissionsOf(installationId);
    if (support == null || support.axes.isEmpty) {
      throw StateError(
        'Karmashala has not established which permission modes this agent '
        'has, so a webhook cannot be armed on it.',
      );
    }
    final asked = arguments['permissionMode'] as String?;
    final PermissionSelection mode;
    if (asked == null || asked.trim().isEmpty) {
      mode = support.selections().firstWhere(
        (s) => support.riskOf(s) == PermissionRisk.readOnly,
        orElse: () => throw StateError(
          'This agent has no read-only mode; name one with permissionMode.',
        ),
      );
    } else {
      mode =
          PermissionSelection.parse(asked) ??
          (throw ArgumentError('permissionMode "$asked" is not a selection.'));
    }
    final risk = support.riskOf(mode);
    if (risk == null) {
      throw ArgumentError('permissionMode "$asked" is not one of its modes.');
    }
    if (risk == PermissionRisk.bypass || support.isDangerous(mode)) {
      throw StateError(
        'An agent cannot arm a webhook that bypasses permissions. NOTHING WAS '
        'DONE. The owner can choose that mode in the app.',
      );
    }
    final perHour = (arguments['callsPerHour'] as num?)?.round();
    final automation = _save(
      Automation(
        id: _newId(),
        repositoryId: required('repositoryId'),
        name: required('name'),
        schedule: AutomationSchedule.once(_now()),
        agentInstallationId: installationId,
        prompt: required('template'),
        permissionMode: mode,
        enabled: true,
        armedAt: _now(),
        modelId: arguments['modelId'] as String?,
        worktree: arguments['worktree'] as bool? ?? false,
        webhook: AutomationWebhook(
          requireSignature: arguments['signatureRequired'] as bool? ?? true,
          callsPerHour: perHour ?? kDefaultWebhookCallsPerHour,
        ),
      ),
    );
    final issued = await _webhooksWork.rotate(automation.id);
    return {
      'id': automation.id,
      'name': automation.name,
      'url': issued.url,
      'permissionMode': mode.canonical,
      'signatureRequired': automation.webhook!.requireSignature,
      'secret': issued.secret,
      'note':
          'This is the only time the secret is shown. Sign calls with it: '
          'X-Hub-Signature-256: sha256=<HMAC-SHA256 of the raw body>.',
    };
  }
}

const List<Map<String, Object?>> webhookToolSchemas = [
  {
    'name': 'webhook_list',
    'description':
        'The webhooks armed on this server: each one an automation that starts '
        'a new session when its URL is called. Answers their URLs and '
        'settings, never their secrets.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'webhook_create',
    'description':
        'Arm a webhook: a URL that, when called with a JSON body, starts a new '
        'session in a checkout with a prompt filled from the body '
        '({{field}} and {{a.b}} paths; values are inserted as quoted data, '
        'never as instructions). Runs read-only unless permissionMode names '
        'another mode; never one that bypasses permissions. Answers the URL '
        'and the signing secret — the only time the secret is shown.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'repositoryId': {
          'type': 'string',
          'description': 'The checkout to start in (list_checkouts).',
        },
        'agentInstallationId': {
          'type': 'string',
          'description': 'The agent to start (list_agents).',
        },
        'template': {
          'type': 'string',
          'description': 'The prompt, with {{field}} paths into the body.',
        },
        'permissionMode': {
          'type': 'string',
          'description': 'A canonical selection such as "mode=plan".',
        },
        'modelId': {'type': 'string'},
        'worktree': {
          'type': 'boolean',
          'description': 'Start each call in a worktree of its own.',
        },
        'signatureRequired': {
          'type': 'boolean',
          'description': 'Require an HMAC signature (default true).',
        },
        'callsPerHour': {'type': 'integer', 'minimum': 1},
      },
      'required': ['name', 'repositoryId', 'agentInstallationId', 'template'],
    },
  },
];
