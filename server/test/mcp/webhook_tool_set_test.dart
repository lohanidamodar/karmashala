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

void main() {
  late List<Automation> saved;
  late _Webhooks webhooks;
  late WebhookToolSet tools;

  setUp(() {
    saved = [];
    webhooks = _Webhooks();
    tools = WebhookToolSet(
      save: (automation) {
        final stored = automation.copyWith(
          webhook: automation.webhook!.copyWith(hookId: 'h1'),
        );
        saved.add(stored);
        return stored;
      },
      webhooks: () => saved,
      work: () => webhooks,
      permissionsOf: (installationId) =>
          installationId == 'a1' ? _support : null,
      now: () => DateTime.utc(2026, 10, 6),
      newId: () => 'auto-new',
    );
  });

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, dynamic> args,
  ) async =>
      jsonDecode(jsonEncode(await tools.call(tool, args, 'caller')))
          as Map<String, Object?>;

  test('create arms a webhook read-only by default and answers its secret '
      'once', () async {
    final made = await call('webhook_create', {
      'name': 'triage-issue',
      'repositoryId': 'r1',
      'agentInstallationId': 'a1',
      'template': 'Triage {{issue.title}}',
    });
    expect(made['secret'], 'whsec_once');
    expect(made['url'], 'https://relay.example.com/h/l/h1');
    final automation = saved.single;
    expect(
      automation.permissionMode,
      const PermissionSelection({'mode': 'plan'}),
    );
    expect(automation.webhook!.requireSignature, isTrue);
    expect(automation.prompt, 'Triage {{issue.title}}');
    expect(webhooks.rotated, ['auto-new']);
  });

  test('list never answers a secret', () async {
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
    final hooks = listed['webhooks']! as List;
    expect((hooks.single as Map)['name'], 'triage-issue');
    expect((hooks.single as Map)['url'], 'https://relay.example.com/h/l/h1');
  });

  test('an agent cannot arm a webhook that bypasses permissions', () async {
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

  test('create needs the operator grant; list does not', () {
    expect(mcpToolNeedsOperatorGrant('webhook_create'), isTrue);
    expect(mcpToolNeedsOperatorGrant('webhook_list'), isFalse);
    expect(kMcpToolAnnotations['webhook_list']!.readOnly, isTrue);
    expect(
      [for (final s in tools.schemas) s['name']],
      ['webhook_list', 'webhook_create'],
    );
  });
}
