import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// **A draft keeps its pictures**: an image pasted into a session's box stays
/// with the half-typed text when the view closes or moves to another session,
/// comes back with it, goes with the message, and its file is cleaned up when
/// it is taken out of the box.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.sessionWork
      ..typesSends = true
      ..resumesOnSend = true;
    for (final id in ['one', 'two']) {
      db.server.sessionRows.insert(
        session(
          id: id,
          agentInstallationId: 'acp',
          status: SessionStatus.failed,
        ),
      );
    }
  });

  /// Mounts whatever [views] says. [elsewhere] is a phone's: the server is
  /// another machine, and the box is drawn for a thumb.
  Future<void> pump(
    WidgetTester tester,
    ValueNotifier<List<(String key, String sessionId)>> views, {
    bool elsewhere = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('pasteboard');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'image') return null;
      if (!Platform.isWindows) return _png;
      final file = File(
        '${Directory.systemTemp.createTempSync('composer').path}/clip.png',
      )..writeAsBytesSync(_png);
      return file.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          ServerOffer(
            sameMachine: !elsewhere,
            serverOs: 'windows',
            features: const {
              'sessions.send',
              'sessions.interrupt',
              'sessions.send.resumes',
              'files.upload',
            },
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => false),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: UiDensityScope(
              density: elsewhere ? UiDensity.touch : UiDensity.pointer,
              child: ValueListenableBuilder(
                valueListenable: views,
                builder: (_, shown, _) => Column(
                  children: [
                    for (final (key, sessionId) in shown)
                      Expanded(
                        key: ValueKey(key),
                        child: SessionTranscriptView(sessionId: sessionId),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder box(String key) => find
      .descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      )
      .last;

  Future<void> show(
    WidgetTester tester,
    ValueNotifier<List<(String, String)>> views,
    List<(String, String)> shown,
  ) async {
    views.value = shown;
    await tester.pumpAndSettle();
  }

  /// Ctrl+V with a picture on the clipboard, into [key]'s box.
  Future<void> paste(WidgetTester tester, String key) async {
    await tester.tap(box(key));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  const pastedChip =
      'Saved to a temp folder and sent to the agent as a file path.';

  /// The pasted image's chip, by the name it was saved under.
  Finder pastedName() => find.textContaining(RegExp(r'^img_\d+\.png$'));

  /// Where the pasted image's file is, named by its chip: other tests paste
  /// into the same folder at the same time.
  String pastedPath(WidgetTester tester) {
    final name = tester.widget<Text>(pastedName()).data!;
    return '${Directory.systemTemp.path}/karmashala/attachments/$name';
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(
      find.byTooltip('Send (Enter) · Shift + Enter for a new line'),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a pasted image survives the view closing and opening again, '
      'and goes with the message', (tester) async {
    final views = ValueNotifier([('peek', 'one')]);
    await pump(tester, views);
    await tester.enterText(box('peek'), 'look at this');
    await paste(tester, 'peek');
    expect(find.byTooltip(pastedChip), findsOneWidget);
    final path = pastedPath(tester);

    await show(tester, views, []);
    await show(tester, views, [('peek again', 'one')]);

    expect(find.byTooltip(pastedChip), findsOneWidget);
    expect(
      tester.widget<TextField>(box('peek again')).controller!.text,
      'look at this',
    );

    await send(tester);
    final sent = server.sessionWork.sent.last.text;
    expect(sent, contains('look at this'));
    expect(sent, contains('Attached image(s):'));
    // The composer joins its folder with /, a listing with the platform's.
    expect(sent, contains(path.split(RegExp(r'[\\/]')).last));
    expect(
      File(path).existsSync(),
      isTrue,
      reason: 'the agent has yet to read what it was sent',
    );

    // Sent is gone from the draft: nothing comes back.
    await show(tester, views, []);
    await show(tester, views, [('third', 'one')]);
    expect(find.byTooltip(pastedChip), findsNothing);
  });

  testWidgets('a pasted image stays with its session when the view moves to '
      'another, and comes back to it', (tester) async {
    final views = ValueNotifier([('view', 'one')]);
    await pump(tester, views);
    await paste(tester, 'view');
    expect(find.byTooltip(pastedChip), findsOneWidget);

    await show(tester, views, [('view', 'two')]);
    expect(find.byTooltip(pastedChip), findsNothing);

    await show(tester, views, [('view', 'one')]);
    expect(find.byTooltip(pastedChip), findsOneWidget);
  });

  testWidgets('an image taken out of the draft has its file deleted', (
    tester,
  ) async {
    final views = ValueNotifier([('view', 'one')]);
    await pump(tester, views);
    await paste(tester, 'view');
    final path = pastedPath(tester);
    await show(tester, views, []);
    await show(tester, views, [('view', 'one')]);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    expect(find.byTooltip(pastedChip), findsNothing);
    expect(File(path).existsSync(), isFalse);
  });

  testWidgets('on a phone, a picture waiting for Send is kept as a file, '
      'survives the view closing, and is uploaded and tidied by Send', (
    tester,
  ) async {
    final views = ValueNotifier([('page', 'one')]);
    await pump(tester, views, elsewhere: true);
    await paste(tester, 'page');
    expect(pastedName(), findsOneWidget);
    expect(server.filesWork.uploaded, isEmpty, reason: 'a phone waits');
    final held = pastedPath(tester);
    expect(
      File(held).existsSync(),
      isTrue,
      reason: 'held on disk, not in memory',
    );

    await show(tester, views, []);
    await show(tester, views, [('page again', 'one')]);
    expect(pastedName(), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Send'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    expect(server.filesWork.uploaded, hasLength(1));
    expect(
      server.sessionWork.sent.last.text,
      contains(server.filesWork.uploaded.single.path),
    );
    expect(File(held).existsSync(), isFalse, reason: 'it is on the server');
  });
}
