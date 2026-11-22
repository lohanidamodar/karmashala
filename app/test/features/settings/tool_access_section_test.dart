import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/settings/presentation/tool_access_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/catalogue.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// Settings › Permissions › Tool access, and a project page's own overrides.
void main() {
  late FakeDataServer server;

  Future<void> pump(
    WidgetTester tester,
    Widget body, {
    Size size = const Size(1440, 900),
    double textScale = 1,
    Set<String> features = const {AgentsToolAccessSet.feature},
    Map<String, Object?> policy = const {},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = FakeDataServer(clock: () => testTime)..toolAccess = policy;
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        serverOfferProvider.overrideWithValue(
          ServerOffer(sameMachine: true, features: features),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: SingleChildScrollView(child: body)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  McpToolAccessPolicy held() => McpToolAccessPolicy.fromJson(server.toolAccess);

  Finder groupSwitch(McpToolGroup group) => find.descendant(
    of: find.byKey(ValueKey('tool-access:${group.id}')),
    matching: find.byType(Switch),
  );

  bool switchOn(WidgetTester tester, McpToolGroup group) =>
      tester.widget<Switch>(groupSwitch(group)).value;

  group('the global settings', () {
    testWidgets('show each group at its default, and a switch sets it', (
      tester,
    ) async {
      await pump(tester, const ToolAccessSection());
      expect(find.text('TOOL ACCESS'), findsOneWidget);
      for (final group in McpToolGroup.values) {
        expect(find.text(group.label), findsOneWidget);
        expect(switchOn(tester, group), group.defaultOn, reason: group.id);
      }

      await tester.tap(groupSwitch(McpToolGroup.answer));
      await tester.pumpAndSettle();
      expect(held().groupOn(McpToolGroup.answer), isTrue);
      expect(switchOn(tester, McpToolGroup.answer), isTrue);

      // Back to its default, nothing is kept for it.
      await tester.tap(groupSwitch(McpToolGroup.answer));
      await tester.pumpAndSettle();
      expect(server.toolAccess, isEmpty);
    });

    testWidgets('Any project widens Message sessions', (tester) async {
      await pump(tester, const ToolAccessSection());
      final any = find.descendant(
        of: find.byKey(const ValueKey('tool-access:message-any-project')),
        matching: find.byType(Switch),
      );
      await tester.tap(any);
      await tester.pumpAndSettle();
      expect(held().messageAnyProject, isTrue);
    });

    testWidgets('Advanced sets one tool, Default clears it', (tester) async {
      await pump(tester, const ToolAccessSection());
      await tester.tap(find.text('Advanced: Pipelines and worktrees'));
      await tester.pumpAndSettle();
      const row = ValueKey('tool-access:global:pipelines:pipeline_run');
      Finder level(String label) =>
          find.descendant(of: find.byKey(row), matching: find.text(label));
      await tester.ensureVisible(find.byKey(row));
      await tester.tap(level('On'));
      await tester.pumpAndSettle();
      expect(held().toolOn('pipeline_run'), isTrue);
      expect(held().toolOn('pipeline_approve'), isFalse);

      await tester.tap(level('Default'));
      await tester.pumpAndSettle();
      expect(server.toolAccess, isEmpty);
    });

    testWidgets('shows what the server holds', (tester) async {
      await pump(
        tester,
        const ToolAccessSection(),
        policy: const {
          'groups': {'start': false},
        },
      );
      expect(switchOn(tester, McpToolGroup.start), isFalse);
    });

    testWidgets('a refusal leaves the switch and says why', (tester) async {
      await pump(tester, const ToolAccessSection());
      server.toolAccessRefusal = 'this device was not granted start_session';
      await tester.tap(groupSwitch(McpToolGroup.panes));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(switchOn(tester, McpToolGroup.panes), isFalse);
      expect(find.textContaining('not granted start_session'), findsOneWidget);
    });

    testWidgets('an older server hides the section', (tester) async {
      await pump(tester, const ToolAccessSection(), features: const {});
      expect(find.text('TOOL ACCESS'), findsNothing);
    });
  });

  group('a project\'s overrides', () {
    Finder picker(McpToolGroup group) =>
        find.byKey(ValueKey('project-tool-access-picker:${group.id}'));

    testWidgets('inherit until set, and are kept for that project alone', (
      tester,
    ) async {
      await pump(tester, const ProjectToolAccessRows(projectId: 'p1'));
      expect(find.textContaining('Inherited: on'), findsNWidgets(2));
      await tester.tap(
        find.descendant(
          of: picker(McpToolGroup.message),
          matching: find.text('Off'),
        ),
      );
      await tester.pumpAndSettle();
      expect(held().toolOn('session_send', projectId: 'p1'), isFalse);
      expect(held().toolOn('session_send'), isTrue);

      await tester.tap(
        find.descendant(
          of: picker(McpToolGroup.message),
          matching: find.text('Inherit'),
        ),
      );
      await tester.pumpAndSettle();
      expect(server.toolAccess, isEmpty);
    });
  });

  for (final (name, size, scale) in const [
    ('a 360 px phone', Size(360, 740), 1.0),
    ('a phone at text scale 1.6', Size(360, 740), 1.6),
    ('the minimum window at text scale 1.6', Size(720, 560), 1.6),
    ('a desktop', Size(1440, 900), 1.6),
    ('a wide desktop', Size(2560, 1440), 1.0),
  ]) {
    testWidgets('fits $name, folds open', (tester) async {
      await pump(
        tester,
        const Column(
          children: [
            ToolAccessSection(),
            ProjectToolAccessRows(projectId: 'p1'),
          ],
        ),
        size: size,
        textScale: scale,
      );
      for (final group in McpToolGroup.values) {
        for (var i = 0; i < 2; i++) {
          final title = find.text('Advanced: ${group.label}').at(i);
          await tester.ensureVisible(title);
          await tester.pumpAndSettle();
          await tester.tap(title);
          await tester.pumpAndSettle();
        }
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(ToolAccessLevelPicker), findsWidgets);
    });
  }
}
