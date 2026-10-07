import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/webhooks_work.dart';
import 'package:karmashala_host/src/mcp/tools/webhook_tool_set.dart';
import 'package:karmashala_mcp/karmashala_mcp.dart'
    show kMcpToolAnnotations, mcpToolNeedsOperatorGrant;
import 'package:test/test.dart';

/// Read-only, ask, and bypass on one axis — the shape every descriptor uses.
AgentPermissionValue _value(String id, PermissionRisk permits) =>
    AgentPermissionValue(
      id: id,
      label: id,
      shortLabel: id,
      description: id,
      arguments: ['--mode', id],
      permits: permits,
      evidence: 'test',
      isDangerous: permits == PermissionRisk.bypass,
    );

final _support = AgentPermissionSupport.axes(
  evidence: 'test',
  axes: [
    AgentPermissionAxis(
      id: 'mode',
      label: 'Mode',
      description: 'Mode',
      defaultValueId: 'ask',
      values: [
        _value('plan', PermissionRisk.readOnly),
        _value('ask', PermissionRisk.ask),
        _value('yolo', PermissionRisk.bypass),
      ],
    ),
  ],
);

class _Webhooks implements WebhooksWork {
  final rotated = <String>[];
  @override
  Future<WebhookIssued> rotate(String automationId) async {
    rotated.add(automationId);
    return WebhookIssued(
      automationId: automationId,
      hookId: 'h1',
      url: 'https://relay.example.com/h/l/h1',
      secret: 'whsec_once',
    );
  }

  @override
  Future<WebhookStatus> status(String automationId, {int limit = 50}) async =>
      const WebhookStatus(
        url: 'https://relay.example.com/h/l/h1',
        listening: true,
        problem: null,
        calls: [],
      );
}

/// An agent proposes; the owner turns on. Every tool here saves what it is
/// asked for off, marked as the caller's proposal, and answers no secret.
void main() {
  late List<Automation> saved;
  late List<Automation> filed;
  late _Webhooks webhooks;
  late WebhookToolSet tools;

  setUp(() {
    saved = [];
    filed = [];
    webhooks = _Webhooks();
    tools = WebhookToolSet(
      save: (automation) {
        final stored = automation.webhook == null
            ? automation
            : automation.copyWith(
                webhook: automation.webhook!.copyWith(hookId: 'h1'),
              );
        saved.add(stored);
        return stored;
      },
      webhooks: () => [
        for (final a in saved)
          if (a.isWebhook) a,
      ],
      work: () => webhooks,
      permissionsOf: (installationId) =>
          installationId == 'a1' ? _support : null,
      now: () => DateTime.utc(2026, 10, 6),
      newId: () => 'auto-new',
      proposerOf: (sessionId) => 'Claude Code in "Fix the cart"',
      proposed: filed.add,
    );
  });

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, dynamic> args,
  ) async =>
      jsonDecode(jsonEncode(await tools.call(tool, args, 'caller')))
          as Map<String, Object?>;

  test('webhook_create proposes a webhook: off, read-only, marked, and no '
      'secret or URL for the agent', () async {
    final made = await call('webhook_create', {
      'name': 'triage-issue',
      'repositoryId': 'r1',
      'agentInstallationId': 'a1',
      'template': 'Triage {{issue.title}}',
    });
    expect(made['proposed'], isTrue);
    expect(made['enabled'], isFalse);
    expect(jsonEncode(made), isNot(contains('whsec_')));
    expect(made.containsKey('url'), isFalse);
    expect(webhooks.rotated, isEmpty, reason: 'the secret is the owner\'s');
    final automation = saved.single;
    expect(automation.enabled, isFalse);
    expect(automation.proposedBy, 'Claude Code in "Fix the cart"');
    expect(automation.proposedSessionId, 'caller');
    expect(
      automation.permissionMode,
      const PermissionSelection({'mode': 'plan'}),
    );
    expect(automation.webhook!.requireSignature, isTrue);
    expect(filed.single.id, 'auto-new', reason: 'filed in the inbox');
  });

  test('no argument turns a proposal on', () async {
    await call('automation_propose', {
      'name': 'Nightly',
      'repositoryId': 'r1',
      'agentInstallationId': 'a1',
      'prompt': 'run the tests',
      'enabled': true,
      'armed': true,
      'trigger': {'type': 'schedule', 'cron': '0 3 * * *', 'enabled': true},
    });
    expect(saved.single.enabled, isFalse);
    expect(saved.single.isProposed, isTrue);
    expect(saved.single.schedule.cron, '0 3 * * *');
  });

  test(
    'automation_propose takes a GitHub trigger, an event and its steps',
    () async {
      await call('automation_propose', {
        'name': 'PR comments',
        'repositoryId': 'r1',
        'agentInstallationId': 'a1',
        'prompt': 'Answer {{github.comment.body}}',
        'trigger': {
          'type': 'github',
          'github': {'kind': 'pr_comment', 'repository': 'acme/shop'},
        },
        'steps': [
          {'kind': 'notify', 'when': 'always', 'text': 'done'},
        ],
      });
      final github = saved.single.github!;
      expect(github.kind, GithubTriggerKind.prComment);
      expect(github.repository, 'acme/shop');
      expect(saved.single.steps.of(AutomationStepKind.notify)!.text, 'done');

      saved.clear();
      await call('automation_propose', {
        'name': 'Needs me',
        'repositoryId': 'r1',
        'trigger': {
          'type': 'event',
          'event': 'needs_you',
          'action': 'notify_only',
        },
      });
      expect(saved.single.agentInstallationId, isEmpty);
      expect(saved.single.trigger!.kind, AutomationEventKind.needsYou);
    },
  );

  test(
    'a proposal that could not be saved says why and saves nothing',
    () async {
      for (final trigger in [
        {'type': 'schedule', 'cron': 'every day'},
        {'type': 'later'},
        {
          'type': 'github',
          'github': {'kind': 'pr_comment', 'repository': 'not a repo'},
        },
      ]) {
        await expectLater(
          tools.call('automation_propose', {
            'name': 'x',
            'repositoryId': 'r1',
            'agentInstallationId': 'a1',
            'prompt': 'go',
            'trigger': trigger,
          }, 'caller'),
          throwsA(isA<ArgumentError>()),
          reason: '$trigger',
        );
      }
      await expectLater(
        tools.call('automation_propose', {
          'name': 'x',
          'repositoryId': 'r1',
          'agentInstallationId': 'a1',
          'prompt': 'go',
          'trigger': {'type': 'schedule', 'everyMinutes': 30},
          'steps': [
            {'kind': 'command', 'text': 'git push {{github.pr.branch}}'},
          ],
        }, 'caller'),
        throwsA(isA<ArgumentError>()),
      );
      expect(saved, isEmpty);
    },
  );

  test('list never answers a secret, nor a proposal\'s URL', () async {
    await call('webhook_create', {
      'name': 'triage-issue',
      'repositoryId': 'r1',
      'agentInstallationId': 'a1',
      'template': 'Triage {{issue.title}}',
    });
    final listed = await call('webhook_list', {});
    final text = jsonEncode(listed);
    expect(text, isNot(contains('whsec_')));
    expect(text, isNot(contains('secret')));
    final hook = (listed['webhooks']! as List).single as Map;
    expect(hook['proposed'], isTrue);
    expect(hook.containsKey('url'), isFalse);
  });

  test('an agent cannot propose one that bypasses permissions', () async {
    await expectLater(
      tools.call('webhook_create', {
        'name': 'x',
        'repositoryId': 'r1',
        'agentInstallationId': 'a1',
        'template': 'go',
        'permissionMode': 'mode=yolo',
      }, 'caller'),
      throwsA(isA<StateError>()),
    );
    expect(saved, isEmpty);
  });

  test('an agent whose modes nobody established is refused', () async {
    await expectLater(
      tools.call('webhook_create', {
        'name': 'x',
        'repositoryId': 'r1',
        'agentInstallationId': 'unknown',
        'template': 'go',
      }, 'caller'),
      throwsA(isA<StateError>()),
    );
  });

  test('proposing needs the operator grant; list does not', () {
    expect(mcpToolNeedsOperatorGrant('webhook_create'), isTrue);
    expect(mcpToolNeedsOperatorGrant('automation_propose'), isTrue);
    expect(mcpToolNeedsOperatorGrant('webhook_list'), isFalse);
    expect(kMcpToolAnnotations['webhook_list']!.readOnly, isTrue);
    expect(
      [for (final s in tools.schemas) s['name']],
      ['webhook_list', 'webhook_create', 'automation_propose'],
    );
  });
}
