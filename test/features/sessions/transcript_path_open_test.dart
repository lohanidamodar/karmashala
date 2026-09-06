import 'dart:io';

import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/path_translator.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_event.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// What a click on a path in the conversation actually does — and, the headline
/// requirement, what **rendering** one costs.
///
/// The whole feature rests on one promise: detection is by shape, so a
/// transcript full of path-shaped tokens touches no disk at all until somebody
/// asks for one. That is counted here, never timed.
void main() {
  const repoRoot = r'C:\src\demo\app';

  late AppDatabase db;
  late FakeCommandRunner host;
  late List<String> probed;
  late FileSystemEntityType answer;

  /// Seeds one session in [environment], running in [workingDirectory].
  void seed({
    ExecutionEnvironment? environment,
    EnvironmentPath? workingDirectory,
  }) {
    final env = environment ?? windowsEnv();
    ExecutionEnvironmentDao(db).upsert(env);
    if (env.id != 'windows') ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Work',
        useWorktree: false,
        workingDirectory: workingDirectory,
        status: SessionStatus.running,
        createdAt: testTime,
        // The event-log rendering, not the PTY transcript: this test is about
        // what a click does, not about where the messages came from.
        surface: SessionSurface.external,
      ),
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    host = FakeCommandRunner();
    probed = [];
    answer = FileSystemEntityType.file;
  });

  tearDown(() => db.close());

  /// Pumps the conversation over one agent message.
  ///
  /// [environments] is what the reveal helper may resolve — an empty list is a
  /// host that cannot place the path at all, which is the case `canReveal`
  /// exists to answer.
  Future<void> pump(
    WidgetTester tester,
    String text, {
    String? root = repoRoot,
    List<ExecutionEnvironment> environments = const [],
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionTranscriptProvider.overrideWith(
            (ref, id) => Stream.value([
              SessionEvent(
                id: 1,
                sessionId: 's1',
                seq: 0,
                type: SessionEventTypes.agentMessage,
                payload: '{"text":${_json(text)}}',
                createdAt: testTime,
              ),
            ]),
          ),
          selectedRepoWindowsRootProvider.overrideWithValue(root),
          // The one disk touch the feature is allowed. Counted, so "nothing is
          // statted while rendering" is a number rather than a claim.
          hostPathProbeProvider.overrideWithValue((path) {
            probed.add(path);
            return answer;
          }),
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: host,
              translator: const PathTranslator(),
              environmentFor: (id) =>
                  environments.where((e) => e.id == id).firstOrNull,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Clicks the first path link in the conversation.
  Future<void> clickPath(WidgetTester tester) async {
    TapGestureRecognizer? link;
    for (final widget in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    )) {
      widget.textSpan?.visitChildren((span) {
        if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
          link ??= span.recognizer! as TapGestureRecognizer;
        }
        return true;
      });
    }
    link!.onTap!();
    await tester.pumpAndSettle();
  }

  ProviderContainer scope(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(SessionTranscriptView)),
  );

  testWidgets('a relative path resolves against the session working directory', (
    tester,
  ) async {
    // Not the process cwd, and not the repository root either: this session was
    // started one folder down.
    seed(
      workingDirectory: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\app\sub',
      ),
    );
    await pump(tester, 'Built windows/installer/output/Setup-1.4.0.exe.');

    await clickPath(tester);

    expect(probed, [r'C:\src\demo\app\sub\windows\installer\output\Setup-1.4.0.exe']);
  });

  testWidgets('with no working directory recorded, the repository root is the '
      'fallback', (tester) async {
    seed();
    await pump(tester, 'See lib/main.dart.');

    await clickPath(tester);

    expect(probed, [r'C:\src\demo\app\lib\main.dart']);
  });

  testWidgets('a path inside the tree is revealed in the Files panel', (
    tester,
  ) async {
    seed();
    await pump(tester, 'See lib/main.dart.');

    await clickPath(tester);

    final container = scope(tester);
    expect(
      container.read(fileRevealTargetProvider),
      const FileRevealTarget(
        hostPath: r'C:\src\demo\app\lib\main.dart',
        isDirectory: false,
      ),
    );
    // The panel is brought to the front, and nothing is handed to a file
    // manager: the row in the tree *is* the reveal.
    expect(container.read(sidePanelProvider), SidePanelSurface.files);
    expect(host.requests, isEmpty);
  });

  testWidgets('a folder inside the tree is revealed as a folder', (
    tester,
  ) async {
    seed();
    answer = FileSystemEntityType.directory;
    await pump(tester, 'Look under lib/src/features/ for it.');

    await clickPath(tester);

    expect(
      scope(tester).read(fileRevealTargetProvider)?.isDirectory,
      isTrue,
    );
  });

  testWidgets('a path outside the tree goes to the host file manager', (
    tester,
  ) async {
    seed();
    await pump(
      tester,
      r'Wrote C:\other\place\report.txt earlier.',
      environments: [windowsEnv()],
    );

    await clickPath(tester);

    expect(scope(tester).read(fileRevealTargetProvider), isNull);
    expect(host.requests.single.executable, 'explorer.exe');
    expect(host.requests.single.arguments, [
      r'/select,C:\other\place\report.txt',
    ]);
  });

  testWidgets('a path the host cannot show reports, rather than doing nothing', (
    tester,
  ) async {
    // No environments the reveal helper can resolve: `canReveal` is false, and
    // a click that quietly did nothing is the failure mode this guards.
    seed();
    await pump(tester, r'Wrote C:\other\place\report.txt earlier.');

    await clickPath(tester);

    expect(host.requests, isEmpty);
    expect(find.textContaining('no path on this machine'), findsOneWidget);
  });

  testWidgets('a path that is not on disk says so', (tester) async {
    seed();
    answer = FileSystemEntityType.notFound;
    await pump(tester, 'See lib/gone.dart.');

    await clickPath(tester);

    expect(find.textContaining(r'C:\src\demo\app\lib\gone.dart'), findsOneWidget);
    expect(find.textContaining('is not on disk'), findsOneWidget);
  });

  testWidgets('a path in an SSH session says where the file actually is', (
    tester,
  ) async {
    final remote = sshEnvFixture();
    seed(
      environment: remote,
      workingDirectory: EnvironmentPath(
        environmentId: remote.id,
        path: '/home/me/src/app',
      ),
    );
    await pump(tester, 'Wrote lib/main.dart on the box.', environments: [remote]);

    await clickPath(tester);

    // No host spelling exists, so nothing is statted and nothing is opened.
    expect(probed, isEmpty);
    expect(host.requests, isEmpty);
    expect(find.textContaining('is on build-box, not on this machine'),
        findsOneWidget);
  });

  group('what rendering costs', () {
    /// A conversation the size of a real one, every line carrying paths.
    String crowded() {
      final buffer = StringBuffer();
      for (var i = 0; i < 200; i++) {
        buffer.writeln(
          'Touched lib/src/features/thing_$i.dart and '
          'test/features/thing_${i}_test.dart, plus '
          'windows/installer/output/Setup-1.$i.0.exe — and/or n/a 1/2.',
        );
      }
      return buffer.toString();
    }

    testWidgets('a transcript full of paths costs no disk access at all', (
      tester,
    ) async {
      seed();
      await pump(tester, crowded());

      // Six hundred links drawn. Not one `stat`: the detector reads shape, and
      // a `\\wsl.localhost\…` stat costs ~1.2 ms apiece on a two-second poll.
      expect(probed, isEmpty);

      // ...and one click costs exactly one.
      await clickPath(tester);
      expect(probed, hasLength(1));
    });
  });
}

/// The message text as a JSON string literal.
String _json(String text) =>
    '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
