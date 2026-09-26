import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_model_catalog_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';

/// The picker offers what the CLI reports for this account, and the curated
/// list until it has.
void main() {
  late Directory codexHome;

  setUp(() {
    codexHome = Directory.systemTemp.createTempSync('ks-codex-home');
  });
  tearDown(() => codexHome.deleteSync(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        hostEnvironmentProvider.overrideWithValue({
          'CODEX_HOME': codexHome.path,
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('Codex offers the models its own cache lists', () async {
    File('${codexHome.path}/models_cache.json').writeAsStringSync(
      '{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6-Astra",'
      '"visibility":"list"},{"slug":"gpt-reserve","visibility":"hide"}]}',
    );
    final c = container();
    await c.read(discoveredModelsProvider('codex').future);

    final support = c.read(agentModelSupportProvider('codex'));
    expect(support.models.map((m) => m.id), ['gpt-6-astra']);
    expect(support.isSupported, isTrue);
  });

  test('with no cache the curated list stands', () async {
    final c = container();
    expect(await c.read(discoveredModelsProvider('codex').future), isNull);

    final curated = c
        .read(agentRegistryProvider)
        .byId('codex')!
        .launch
        .model
        .models;
    expect(c.read(agentModelSupportProvider('codex')).models, curated);
  });
}
