import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/presentation/agent_detection_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

const _registry = AgentRegistry([
  AgentDescriptor(
    id: AgentIds.claudeCode,
    displayName: 'Claude Code',
    binaries: AgentBinaries(windows: ['claude'], posix: ['claude']),
  ),
  AgentDescriptor(
    id: AgentIds.codex,
    displayName: 'Codex CLI',
    binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
  ),
]);

void main() {
  late AppDatabase db;
  var installed = <String>{'claude'};

  FakeCommandRunner runner() => FakeCommandRunner(
    responder: (req) {
      if (req.executable == 'where') {
        return installed.contains(req.arguments.first)
            ? CommandResult(
                exitCode: 0,
                stdout: 'C:\\bin\\${req.arguments.first}.exe\r\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '9.9.9', stderr: '');
    },
  );

  setUp(() {
    installed = {'claude'};
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          agentRegistryProvider.overrideWithValue(_registry),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AgentDetectionSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('offers a re-detect control before anything has been scanned', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Detect agents'), findsOneWidget);
    expect(find.textContaining('Not scanned yet'), findsOneWidget);
  });

  testWidgets('reports what it found and what it did not', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Detect agents'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 agent'), findsOneWidget);
    // The half that this codebase has been burned by: an operation that
    // reports success while saying nothing about what it did not do.
    expect(find.textContaining('Codex CLI'), findsOneWidget);
  });

  testWidgets('says plainly when it found nothing', (tester) async {
    installed.clear();
    await pump(tester);
    await tester.tap(find.text('Detect agents'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No agents'), findsOneWidget);
  });

  testWidgets('a second run reports the agent it newly found', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Detect agents'));
    await tester.pumpAndSettle();

    installed.add('codex');
    await tester.tap(find.text('Detect agents'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 agents'), findsOneWidget);
    expect(find.textContaining('1 new'), findsOneWidget);
  });
}
