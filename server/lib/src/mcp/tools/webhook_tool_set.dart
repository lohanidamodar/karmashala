import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/schedules.dart' show cronRefusal;
import 'package:karmashala_automations/webhooks.dart'
    show webhookTemplateRefusal;

import '../../data/webhooks_work.dart';
import 'server_tool_set.dart';

/// `webhook_list`, `webhook_create` and `automation_propose`: an agent sees
/// the webhooks here and **proposes** automations. A proposal is saved off,
/// marked as proposed by its session, and runs nothing until the owner turns
/// it on in the app — arming is a person's act. No tool here can enable one,
/// and a webhook's secret goes to the owner when they turn it on, never to
/// the agent.
class WebhookToolSet extends ServerToolSet {
  WebhookToolSet({
    required Automation Function(Automation automation) save,
    required List<Automation> Function() webhooks,
    required WebhooksWork? Function() work,
    required AgentPermissionSupport? Function(String installationId)
    permissionsOf,
    required DateTime Function() now,
    required String Function() newId,
    String Function(String? sessionId)? proposerOf,
    void Function(Automation proposal)? proposed,
    Future<String?> Function(String reference)? redeemSecret,
  }) : _save = save,
       _webhooks = webhooks,
       _work = work,
       _permissionsOf = permissionsOf,
       _now = now,
       _newId = newId,
       _proposerOf = proposerOf ?? _anAgent,
       _proposed = proposed,
       _redeemSecret = redeemSecret ?? _noSecrets;

  final Automation Function(Automation automation) _save;
  final List<Automation> Function() _webhooks;
  final WebhooksWork? Function() _work;
  final AgentPermissionSupport? Function(String installationId) _permissionsOf;
  final DateTime Function() _now;
  final String Function() _newId;
  final String Function(String? sessionId) _proposerOf;
  final void Function(Automation proposal)? _proposed;
  final Future<String?> Function(String reference) _redeemSecret;

  static Future<String?> _noSecrets(String _) async => null;

  static String? _secretReferenceOf(Map<String, dynamic> arguments) {
    final trigger = arguments['trigger'];
    final value = trigger is Map ? trigger['signingRef'] : null;
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  static String _anAgent(String? _) => 'An agent';

  @override
  List<Map<String, Object?>> get schemas => webhookToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'webhook_list' => runTool(_list),
    'webhook_create' => runTool(
      () => _propose({
        ...arguments,
        'prompt': arguments['template'],
        'trigger': {
          'type': 'webhook',
          'signatureRequired': arguments['signatureRequired'],
          'signingRef': arguments['signingRef'],
          'callsPerHour': arguments['callsPerHour'],
        },
      }, callerSessionId),
    ),
    'automation_propose' => runTool(() => _propose(arguments, callerSessionId)),
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
          'proposed': automation.isProposed,
          'repositoryId': automation.repositoryId,
          'agentInstallationId': automation.agentInstallationId,
          'permissionMode': automation.permissionMode?.canonical,
          'modelId': automation.modelId,
          'worktree': automation.worktree,
          'signatureRequired': automation.webhook!.requireSignature,
          'callsPerHour': automation.webhook!.callsPerHour,
          'template': automation.prompt,
          if (automation.enabled)
            'url': (await _webhooksWork.status(automation.id, limit: 1)).url,
        },
    ],
  };

  /// The mode a proposed agent runs in: read-only unless the agent named
  /// another, and never one that bypasses permissions.
  PermissionSelection _mode(String installationId, String? asked) {
    final support = _permissionsOf(installationId);
    if (support == null || support.axes.isEmpty) {
      throw StateError(
        'Karmashala has not established which permission modes this agent '
        'has, so nothing can be proposed on it.',
      );
    }
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
        'An agent cannot propose an automation that bypasses permissions. '
        'NOTHING WAS DONE. The owner can choose that mode in the app.',
      );
    }
    return mode;
  }

  Future<Object?> _propose(
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) async {
    String required(String key) {
      final value = (arguments[key] as String?)?.trim();
      if (value == null || value.isEmpty) {
        throw ArgumentError('$key is needed.');
      }
      return value;
    }

    final now = _now();
    final trigger = arguments['trigger'];
    if (trigger is! Map) throw ArgumentError('trigger is needed.');
    var schedule = AutomationSchedule.once(now);
    AutomationEventTrigger? event;
    AutomationGithubTrigger? github;
    AutomationWebhook? webhook;
    switch (trigger['type']) {
      case 'schedule':
        final cron = (trigger['cron'] as String?)?.trim();
        final minutes = (trigger['everyMinutes'] as num?)?.round();
        if (cron != null && cron.isNotEmpty) {
          if (cronRefusal(cron) case final why?) throw ArgumentError(why);
          schedule = AutomationSchedule.cron(cron);
        } else if (minutes != null && minutes > 0) {
          schedule = AutomationSchedule.every(Duration(minutes: minutes));
        } else {
          throw ArgumentError('A schedule needs cron or everyMinutes.');
        }
      case 'event':
        final kind = AutomationEventKind.fromStored(
          trigger['event'] as String?,
        );
        final action = AutomationEventAction.fromStored(
          trigger['action'] as String? ?? 'start_session',
        );
        if (kind == null || action == null) {
          throw ArgumentError('An event needs a known event and action.');
        }
        event = AutomationEventTrigger(kind: kind, action: action);
      case 'github':
        github = AutomationGithubTrigger.fromJson({
          'action': 'start_session',
          'pollSeconds': 120,
          ...(trigger['github'] as Map? ?? const {}),
        });
        if (github == null) {
          throw ArgumentError('github needs a known kind and a repository.');
        }
        if (github.refusal case final why?) throw ArgumentError(why);
      case 'webhook':
        webhook = AutomationWebhook(
          requireSignature: trigger['signatureRequired'] as bool? ?? true,
          callsPerHour:
              (trigger['callsPerHour'] as num?)?.round() ??
              kDefaultWebhookCallsPerHour,
        );
        if (webhookTemplateRefusal(required('prompt')) case final why?) {
          throw ArgumentError(why);
        }
      default:
        throw ArgumentError(
          'trigger.type is one of schedule, event, github or webhook.',
        );
    }
    final steps = arguments['steps'] == null
        ? AutomationSteps.none
        : AutomationSteps.fromJson(arguments['steps']);
    if (steps.refusal case final why?) throw ArgumentError(why);
    var proposal = Automation(
      id: _newId(),
      repositoryId: required('repositoryId'),
      name: required('name'),
      schedule: schedule,
      agentInstallationId: '',
      prompt: (arguments['prompt'] as String?)?.trim() ?? '',
      permissionMode: null,
      enabled: false,
      armedAt: now,
      trigger: event,
      github: github,
      webhook: webhook,
      modelId: arguments['modelId'] as String?,
      worktree: arguments['worktree'] as bool? ?? false,
      steps: steps,
      proposedBy: _proposerOf(callerSessionId),
      proposedSessionId: callerSessionId,
    );
    if (proposal.startsAgent) {
      final installationId = required('agentInstallationId');
      proposal = proposal.copyWith(
        agentInstallationId: installationId,
        permissionMode: _mode(
          installationId,
          arguments['permissionMode'] as String?,
        ),
      );
      if (proposal.prompt.isEmpty) throw ArgumentError('prompt is needed.');
    }
    final reference = _secretReferenceOf(arguments);
    if (reference != null && !proposal.isWebhook) {
      throw ArgumentError('signingRef is for a webhook trigger.');
    }
    // Checked before the reference is used up: it is single-use.
    final work = reference == null ? null : _webhooksWork;
    final secret = reference == null ? null : await _redeemSecret(reference);
    if (reference != null && secret == null) {
      throw ArgumentError(
        'signingRef is not a reference this server holds, or it '
        'was already used. Ask again with request_secret.',
      );
    }
    // Saved off whatever was asked: only a person turns it on.
    final saved = _save(proposal.copyWith(enabled: false));
    if (work != null && secret != null) {
      await work.adoptSecret(saved.id, secret);
    }
    _proposed?.call(saved);
    final told = !saved.isWebhook
        ? ''
        : secret != null
        ? ' Its URL goes to them then; it signs with the secret they entered.'
        : ' Its URL and secret go to them then.';
    return {
      'id': saved.id,
      'name': saved.name,
      'enabled': false,
      'proposed': true,
      'permissionMode': saved.permissionMode?.canonical,
      'note':
          'Proposed, not armed: it does nothing until the owner reviews it '
          'and turns it on in Automations.'
          '$told',
    };
  }
}

/// The tools that may only propose an automation — saved off, for a person
/// to turn on — and never arm, enable, run or remove one.
const Set<String> kProposeOnlyAutomationTools = {
  'automation_propose',
  'webhook_create',
};

const List<Map<String, Object?>> webhookToolSchemas = [
  {
    'name': 'webhook_list',
    'description':
        'The webhooks on this server: each one an automation that starts a '
        'new session when its URL is called. Answers their settings and, for '
        'one the owner has turned on, its URL — never a secret.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'webhook_create',
    'description':
        'Propose a webhook: a URL that, when called with a JSON body, would '
        'start a new session in a checkout with a prompt filled from the body '
        '({{field}} and {{a.b}} paths, inserted as quoted data). It is saved '
        'off and does nothing until the owner reviews it and turns it on in '
        'the app; its URL and secret go to them then, not to you. Runs '
        'read-only unless permissionMode names another mode; never one that '
        'bypasses permissions.',
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
        'signingRef': {
          'type': 'string',
          'description':
              'A reference request_secret gave you: the webhook is signed '
              'with the secret the owner entered. Used up by this call.',
        },
      },
      'required': ['name', 'repositoryId', 'agentInstallationId', 'template'],
    },
  },
  {
    'name': 'automation_propose',
    'description':
        'Propose an automation for the owner to review: on a schedule, when a '
        'session event happens, when something happens on GitHub, or on a '
        'webhook call. It is saved off, marked as proposed by this session, '
        'and runs nothing until the owner turns it on in the app. Nothing '
        'here can turn one on.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'repositoryId': {
          'type': 'string',
          'description': 'The checkout it runs in (list_checkouts).',
        },
        'agentInstallationId': {
          'type': 'string',
          'description':
              'The agent it starts (list_agents); not needed for one that '
              'only notifies.',
        },
        'prompt': {
          'type': 'string',
          'description':
              'What the agent is told; {{github.…}} or {{field}} values '
              'reach it quoted as data.',
        },
        'permissionMode': {
          'type': 'string',
          'description': 'A canonical selection; read-only by default.',
        },
        'modelId': {'type': 'string'},
        'worktree': {'type': 'boolean'},
        'trigger': {
          'type': 'object',
          'description':
              'type is schedule (cron or everyMinutes), event (event: '
              'turn_finished, turn_failed or needs_you; action: '
              'start_session, message_session or notify_only), github '
              '(github: {kind, repository, action, branch, authors, logins, '
              'label, assignee, pollSeconds}) or webhook '
              '(signatureRequired, callsPerHour, signingRef: a '
              'reference request_secret gave you, to sign with the secret '
              'the owner entered).',
          'properties': {
            'type': {
              'type': 'string',
              'enum': ['schedule', 'event', 'github', 'webhook'],
            },
          },
          'required': ['type'],
        },
        'steps': {
          'type': 'array',
          'description':
              'Steps after the agent: {kind: check|command|webhook|tell|'
              'notify, when: success|failure|always, text, url, name}. A check '
              'is optional; its text is its command, one a line, like '
              '"flutter test".',
          'items': {'type': 'object'},
        },
      },
      'required': ['name', 'repositoryId', 'trigger'],
    },
  },
];
