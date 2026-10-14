import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/presentation/permissions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

void main() {
  testWidgets('says these are defaults, not overrides', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_StaticSettings.new),
          agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PermissionModesSection()),
          ),
        ),
      ),
    );

    // The natural reading of a settings screen is that it governs everything,
    // which is exactly the misunderstanding this page has to head off: a
    // session that picked a mode keeps it when these move.
    expect(
      find.textContaining('a mode picked on a session keeps it').first,
      findsOneWidget,
    );
  });

  testWidgets('each row names its rung beside the CLI own word', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_StaticSettings.new),
          agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PermissionModesSection()),
          ),
        ),
      ),
    );

    // The first card is Claude Code's, and its first dropdown is what a new
    // session starts under.
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    // This page is where somebody configures an agent, so the CLI's own word
    // is the half that must never leave — the borrowed name is only ever in
    // front of it, and only where the CLI does not already say it.
    expect(find.text('Build · Accept edits'), findsWidgets);
    expect(find.text('Build · Automatic'), findsWidgets);
    expect(find.text('Plan mode'), findsWidgets);
    expect(find.text('Bypass (full autonomy)'), findsWidgets);
  });

  testWidgets("a person-added chat agent has a default once its row places "
      'modes, starting on the one that asks; one that places none is left '
      'off', (tester) async {
    final placed = AcpAgentRow(
      id: 'r1',
      name: 'Copilot',
      command: 'copilot',
      createdAt: DateTime.utc(2026),
      modeRungs: const {
        'Plan': PermissionRisk.readOnly,
        'Agent': PermissionRisk.ask,
        'Autopilot': PermissionRisk.bypass,
      },
    );
    final bare = AcpAgentRow(
      id: 'r2',
      name: 'Bare',
      command: 'bare',
      createdAt: DateTime.utc(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_StaticSettings.new),
          agentRegistryProvider.overrideWithValue(
            AgentRegistry.withExtra([
              acpAgentAdapter(placed),
              acpAgentAdapter(bare),
            ]),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PermissionModesSection()),
          ),
        ),
      ),
    );

    expect(find.text('Copilot · new sessions'), findsOneWidget);
    expect(find.text('Copilot · existing sessions'), findsOneWidget);
    expect(find.textContaining('Bare'), findsNothing);
    final support = acpRowPermission(placed);
    expect(support.axes.single.defaultValueId, 'Agent');
    expect(support.axes.single.values.map((v) => v.id), [
      'Plan',
      'Agent',
      'Autopilot',
    ]);
    expect(support.axes.single.values.last.isDangerous, isTrue);
    expect(tester.takeException(), isNull);
  });
}
