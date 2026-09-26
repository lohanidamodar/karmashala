import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_state.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The Explorer's default view, as a reader perceives it**, frozen: every
/// semantics node under the panel with its words and its rectangle.
///
/// The lenses swap the Explorer's body for something else and back. The one
/// promise they make is that the default view — the project tree — is not
/// changed by their existing, so this file is what a lens must leave alone.
/// Semantics rather than the element tree, so a wrapper that draws nothing is
/// not a change; anything a user can see or hear is.
///
/// Regenerate only when the default view is meant to change:
///
/// ```
/// KARMASHALA_WRITE_EXPLORER_GOLDEN=1 flutter test \
///   test/features/explorer/explorer_default_view_test.dart
/// ```
const _goldenPath = 'test/features/explorer/explorer_default_view.golden.txt';

void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.installationRows.insert(agentInstallation());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
    server.repositoryRows
      ..insert(
        repository(
          id: 'r1',
          projectId: 'p1',
          name: 'alpha',
          path: r'C:\src\alpha',
        ),
      )
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p2',
          name: 'beta',
          path: r'C:\src\beta',
        ),
      );
    for (final (id, repo, status) in [
      ('s1', 'r1', SessionStatus.idle),
      ('s2', 'r1', SessionStatus.completed),
      ('s3', 'r2', SessionStatus.running),
    ]) {
      db.server.sessionRows.insert(
        Session(
          id: id,
          repositoryId: repo,
          agentInstallationId: 'a1',
          title: 'Chat $id',
          useWorktree: false,
          status: status,
          createdAt: testTime,
        ),
      );
    }
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('w-')),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await createContext(container, 'Game dev');
    // One project open, so session rows are part of what is frozen.
    container.read(explorerExpandedProjectsProvider.notifier).open('p1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 320,
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: const ExplorerPanel(),
                  ),
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the default view is the committed one', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);
    final dump = explorerSemanticsDump(tester);
    semantics.dispose();

    final contents =
        '# The Explorer\'s default view, as semantics.\n'
        '# Regenerate with KARMASHALA_WRITE_EXPLORER_GOLDEN=1; see\n'
        '# test/features/explorer/explorer_default_view_test.dart.\n'
        '$dump';
    final file = File(_goldenPath);
    if (Platform.environment['KARMASHALA_WRITE_EXPLORER_GOLDEN'] == '1') {
      file.writeAsStringSync(contents);
      // ignore: avoid_print
      print('wrote $_goldenPath');
      return;
    }
    expect(
      file.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; see the header of this file',
    );
    expect(contents, file.readAsStringSync().replaceAll('\r\n', '\n'));
  });
}

/// Every semantics node under the Explorer, depth first: its words and where
/// it is. Nothing offstage has a node, so a hidden lens is not in it.
String explorerSemanticsDump(WidgetTester tester) {
  final root = tester.getSemantics(find.byType(ExplorerPanel));
  final out = StringBuffer();
  String n(double v) => v.toStringAsFixed(1);
  void visit(SemanticsNode node, int depth, Matrix4 parent) {
    final data = node.getSemanticsData();
    final transform = node.transform;
    final toRoot = transform == null ? parent : parent * transform;
    final r = MatrixUtils.transformRect(toRoot, node.rect);
    final parts = [
      if (data.label.isNotEmpty) 'label=${_quote(data.label)}',
      if (data.value.isNotEmpty) 'value=${_quote(data.value)}',
      if (data.tooltip.isNotEmpty) 'tooltip=${_quote(data.tooltip)}',
      if (data.hint.isNotEmpty) 'hint=${_quote(data.hint)}',
      'actions=${data.actions}',
      'rect=(${n(r.left)}, ${n(r.top)}, ${n(r.width)} x ${n(r.height)})',
    ];
    out.writeln('${'  ' * depth}${parts.join(' ')}');
    final children = <SemanticsNode>[];
    node.visitChildren((child) {
      children.add(child);
      return true;
    });
    for (final child in children) {
      visit(child, depth + 1, toRoot);
    }
  }

  visit(root, 0, Matrix4.identity());
  return out.toString();
}

String _quote(String text) => '"${text.replaceAll('\n', r'\n')}"';
