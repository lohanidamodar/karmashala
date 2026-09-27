import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// What a click on a path in the conversation actually does — and, the headline
/// requirement, what **rendering** one costs.
///
/// The whole feature rests on one promise: detection is by shape, so a
/// transcript full of path-shaped tokens touches no disk at all until somebody
/// asks for one. That is counted here, never timed.
void main() {
  const repoRoot = r'C:\src\demo\app';

  late TestMachine db;
  late FakeCommandRunner host;
  late List<String> probed;
  late FileStat onDisk;
  late FakeDataServer server;

  FileStat stat({bool directory = false}) => FileStat(
    isDirectory: directory,
    size: 1,
    stamp: FileStamp(length: 1, modified: testTime),
  );

  /// Seeds one session in [environment], running in [workingDirectory].
  void seed({
    ExecutionEnvironment? environment,
    EnvironmentPath? workingDirectory,
  }) {
    final env = environment ?? windowsEnv();
    server.environmentRows.upsert(env);
    if (env.id != 'windows') server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(
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
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    host = FakeCommandRunner();
    probed = [];
    onDisk = stat();
    // The one disk touch the feature is allowed, asked of the server where
    // the session's files are. Counted, so "nothing is statted while
    // rendering" is a number rather than a claim.
    server.filesWork.answer = (request) {
      if (request is! FilesStatOf) return FakeFilesWork.unhandled;
      probed.add(request.path.path);
      return onDisk;
    };
  });

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
          await server.override(),
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
          fileTreeRootProvider.overrideWithValue(
            root == null
                ? null
                : EnvironmentPath(environmentId: 'windows', path: root),
          ),
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
    // Plain rich text: the transcript's one selection area does the selecting.
    for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
      widget.text.visitChildren((span) {
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

    expect(probed, [
      r'C:\src\demo\app\sub\windows\installer\output\Setup-1.4.0.exe',
    ]);
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
        path: EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app\lib\main.dart',
        ),
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
    onDisk = stat(directory: true);
    await pump(tester, 'Look under lib/src/features/ for it.');

    await clickPath(tester);

    expect(scope(tester).read(fileRevealTargetProvider)?.isDirectory, isTrue);
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
    onDisk = const FileStat.absent();
    await pump(tester, 'See lib/gone.dart.');

    await clickPath(tester);

    expect(
      find.textContaining(r'C:\src\demo\app\lib\gone.dart'),
      findsOneWidget,
    );
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
    await pump(
      tester,
      'Wrote lib/main.dart on the box.',
      environments: [remote],
    );

    await clickPath(tester);

    // The server looks on the box itself (slice 3c); it is there, but no
    // file manager here can show it, so nothing is opened.
    expect(probed, ['/home/me/src/app/lib/main.dart']);
    expect(host.requests, isEmpty);
    expect(
      find.textContaining('is on build-box, not on this machine'),
      findsOneWidget,
    );
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
