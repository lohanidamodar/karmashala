@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'companion_live_harness.dart';
import 'local_host_harness.dart';

/// The phone companion as the daemon serves it, end to end on this machine: a
/// real `karmashala_host serve` in a temporary home and data directory, the
/// app's own lifecycle link configuring it and asking for pairings, and phones
/// built from the phone's own pairing and session clients on loopback. The app
/// hangs up before any phone pairs, so everything a phone gets until the last
/// test is the daemon's own answer.
void main() {
  late Directory home;
  late LocalHost host;
  late int port;
  late LoopbackPhone phone;
  late LoopbackPhone viewer;
  late LocalHostClient observer;

  final hostSessionId = hostSessionIdOf(seededSessionId);

  setUpAll(() async {
    home = temporaryHome('karmashala-companion-live');
    final dataDir = Directory('${home.path}/data');
    seedStore(dataDir);
    host = await LocalHost.start(home);
    addTearDown(host.kill);
    expect(host.greeting, contains('store ${dataDir.path}'));
    port = companionPortOf(host.greeting);
    expect(port, isNot(anyOf(kHostCompanionPort, 47821)));

    // A pane runs the seeded row's session and hangs up, as the app's pane
    // does when the app quits: the session keeps running, nobody drives it.
    final pane = await LocalHostClient.connect(host.socketPath, 'live-pane');
    await pane.expect<WelcomeMessage>();
    pane.send(
      OpenMessage(
        requestId: pane.nextId(),
        sessionId: hostSessionId,
        argv: const ['/bin/cat'],
        workingDirectory: home.path,
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
    );
    final attached = await pane.expect<AttachedMessage>();
    pane.type(attached.sessionRef, 'hello-from-pane');
    expect(
      await pane.output('hello-from-pane'),
      isTrue,
      reason: pane.tail(200),
    );
    await pane.close();

    // Watches without driving, so a prompt's arrival in the PTY is seen as
    // bytes, not inferred from a reply.
    observer = await LocalHostClient.connect(host.socketPath, 'live-observer');
    await observer.expect<WelcomeMessage>();
    observer.send(
      AttachMessage(
        requestId: observer.nextId(),
        sessionId: hostSessionId,
        sinceOffset: 0,
        claimWrite: false,
      ),
    );
    final watching = await observer.expect<AttachedMessage>();
    expect(watching.holdsWriteToken, isFalse);
    addTearDown(observer.close);

    // The app: attached on the link, a pairing window, then gone.
    final app = await AppLink.connect(host.socketPath, asApp: true);
    final everything = await app.pair(CapabilitySet.all);
    await app.close();

    phone = LoopbackPhone(port, name: 'Live phone');
    final paired = await phone.pair(everything);
    expect(paired.capabilities, CapabilitySet.all);

    // A second phone, paired by a link that is not the app (`pair` over SSH),
    // granted everything but typing.
    final sshPair = await AppLink.connect(host.socketPath);
    final noTyping = await sshPair.pair(
      CapabilitySet.of(
        Capability.values.where((c) => c != Capability.sendPrompt),
      ),
    );
    await sshPair.close();
    viewer = LoopbackPhone(port, name: 'Live viewer');
    await viewer.pair(noTyping);
  });

  Future<CompanionClient> dial(LoopbackPhone who) async {
    final client = await who.dial();
    addTearDown(client.close);
    return client;
  }

  test('both pairings are rows in the store the app shares', () {
    final database = AppDatabase.open(Directory('${home.path}/data'));
    addTearDown(database.close);
    final rows = {
      for (final device in PairedDeviceDao(database).getActive())
        device.name: device,
    };

    expect(rows.keys, containsAll(['Live phone', 'Live viewer']));
    expect(rows['Live phone']!.capabilities, CapabilitySet.all);
    expect(rows['Live viewer']!.capabilities.has(Capability.sendPrompt), false);
    expect(
      rows['Live viewer']!.capabilities.has(Capability.viewSessions),
      true,
    );
  });

  group('with the app closed', () {
    test('the hosted session is listed from its row, running', () async {
      final client = await dial(phone);
      final sessions = await client.listSessions();

      final row = sessions.singleWhere((s) => s.sessionId == seededSessionId);
      expect(row.title, seededSessionTitle);
      expect(
        row.status,
        'running',
        reason: 'the daemon recorded its own start over the seeded `created`',
      );
      expect(row.repositoryName, 'shop-api');
      expect(row.projectName, 'Shop');
      expect(row.whereabouts, 'running on ${Platform.localHostname}');
      expect(
        sessions.where((s) => s.sessionId == hostSessionId),
        isEmpty,
        reason: 'the row\'s own session is not listed a second time',
      );
    });

    test('its transcript is the screen the PTY drew', () async {
      final client = await dial(phone);
      final page = await client.transcript(seededSessionId);

      expect(page.absence, isNull);
      expect(page.messages, isNotEmpty);
      expect(page.messages.last.text, contains('hello-from-pane'));
    });

    test('a prompt is typed into the PTY and shows on the screen', () async {
      final client = await dial(phone);
      final delivery = await client.sendPrompt(
        seededSessionId,
        'typed-by-phone',
      );

      expect(delivery, RemotePromptDelivery.sent);
      expect(
        await observer.output('typed-by-phone'),
        isTrue,
        reason: observer.tail(300),
      );
      final page = await readUntil(
        () => client.transcript(seededSessionId),
        (page) =>
            page.messages.isNotEmpty &&
            page.messages.last.text.contains('typed-by-phone'),
      );
      expect(page.messages.last.text, contains('typed-by-phone'));
    });

    test('notes and todos come from the store', () async {
      final client = await dial(phone);
      final notes = await client.notes();

      expect(notes.notesEnabled, isTrue);
      expect(notes.notes.single.body, seededNote);
      expect(notes.notes.single.projectName, 'Shop');
      expect(notes.todos.single.body, seededTodo);
    });

    test('an agent the store does not hold is refused by name', () async {
      final client = await dial(phone);

      await expectLater(
        client.startSession(
          requestId: 'live-start',
          repositoryId: 'r1',
          installationId: 'a1',
          permissionMode: 'default',
        ),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.message,
            'message',
            'that agent is no longer installed on this machine',
          ),
        ),
      );
    });

    test(
      'a phone paired without typing reads but is refused a prompt',
      () async {
        final client = await dial(viewer);

        final sessions = await client.listSessions();
        expect(sessions.map((s) => s.sessionId), contains(seededSessionId));
        await expectLater(
          client.sendPrompt(seededSessionId, 'must-not-arrive'),
          throwsA(
            isA<RemoteApiException>().having(
              (e) => e.code,
              'code',
              ErrorCode.notPermitted,
            ),
          ),
        );
        // The refusal is the host's, before the PTY: a later prompt from the
        // phone that may type is what arrives, and this one never does.
        final typist = await dial(phone);
        await typist.sendPrompt(seededSessionId, 'after-the-refusal');
        expect(await observer.output('after-the-refusal'), isTrue);
        expect(observer.tail(4000), isNot(contains('must-not-arrive')));
      },
    );
  });

  // The agent's status and its prompts are the daemon's: with no app
  // connected, a phone sees the permission prompt and answers it, and the key
  // reaches the agent's PTY. The agent is a stand-in that draws Claude Code's
  // real permission modal (a captured PTY stream) and reports the line it
  // reads back.
  group('a hosted agent\'s prompt, with the app closed', () {
    late LocalHostClient agentObserver;

    /// Starts the fake agent in the seeded agent row's host session, as a pane
    /// that then goes away, and watches its bytes without driving it.
    Future<void> startAgent() async {
      final captured = File(
        '../app/test/features/agents/fixtures/claude-code-permission-modal.raw',
      ).readAsStringSync();
      final teardown = captured.indexOf('Session terminated');
      final screen = File('${home.path}/permission-modal.raw')
        ..writeAsStringSync(
          teardown < 0 ? captured : captured.substring(0, teardown),
        );
      final pane = await LocalHostClient.connect(host.socketPath, 'agent-pane');
      await pane.expect<WelcomeMessage>();
      pane.send(
        OpenMessage(
          requestId: pane.nextId(),
          sessionId: hostSessionIdOf(seededAgentSessionId),
          argv: [
            '/bin/sh',
            '-c',
            'cat "\$1"; read -r line; echo "ANSWERED<\$line>"; sleep 120',
            'fake-agent',
            screen.path,
          ],
          workingDirectory: home.path,
          environment: const {'TERM': 'xterm-256color'},
          columns: 120,
          rows: 30,
        ),
      );
      await pane.expect<AttachedMessage>();
      // The pane goes, as the app's does when it quits: the agent runs on.
      await pane.close();

      agentObserver = await LocalHostClient.connect(
        host.socketPath,
        'agent-observer',
      );
      await agentObserver.expect<WelcomeMessage>();
      agentObserver.send(
        AttachMessage(
          requestId: agentObserver.nextId(),
          sessionId: hostSessionIdOf(seededAgentSessionId),
          sinceOffset: 0,
          claimWrite: false,
        ),
      );
      await agentObserver.expect<AttachedMessage>();
      addTearDown(agentObserver.close);
    }

    test('the phone sees it waiting, reads the menu and approves', () async {
      // The prompt opens with no phone there; the phone dials in after it.
      await startAgent();
      final client = await dial(phone);
      // Listening from the moment it is connected, as the phone's gateway
      // does: the news may come on this link before the session is opened,
      // and a stream nobody listens to yet keeps nothing (the order this test
      // once had to be turned round for).
      final asked = client.events
          .where((e) => e is ApprovalRequestedEvent)
          .cast<ApprovalRequestedEvent>()
          .first;

      final listed = await readUntil(
        client.listSessions,
        (sessions) => sessions.any(
          (s) =>
              s.sessionId == seededAgentSessionId &&
              s.attention == kAttentionNeedsApproval,
        ),
      );
      expect(
        listed
            .singleWhere((s) => s.sessionId == seededAgentSessionId)
            .attention,
        kAttentionNeedsApproval,
        reason: 'read off the screen by the daemon, with no app',
      );

      // Opening the session: a prompt already open when the phone came is
      // announced now, if it was not on this link already.
      await client.subscribeSession(seededAgentSessionId);
      final request = (await asked.timeout(
        const Duration(seconds: 20),
      )).request;
      expect(request.waiting, RemoteWaitKind.approval);
      expect(request.menu, isNotNull, reason: 'the modal is a menu');
      expect(request.menu!.options.first, 'Yes');

      expect(
        await client.answerApproval(seededAgentSessionId, approve: true),
        'Yes',
      );
      expect(
        await agentObserver.output('ANSWERED<>'),
        isTrue,
        reason: agentObserver.tail(400),
      );
    });
  });

  // A phone driving the machine on its own, as on a server with no desktop:
  // it lists what is here, adds a folder as a project, starts an agent in it
  // (a stand-in script under Claude Code's adapter), sees it running, lets it
  // end, and resumes it — no app link anywhere.
  group('a phone driving the machine alone', () {
    test(
      'lists, adds a project, starts, sees it run, and resumes it',
      () async {
        final client = await dial(phone);

        final places = await client.listProjects();
        expect(places.map((p) => p.name), contains('Shop'));

        final folder = Directory('${home.path}/new-project');
        Directory('${folder.path}/.git').createSync(recursive: true);
        final added = await client.addProject(
          requestId: 'live-add',
          name: 'New project',
          path: folder.path,
        );
        expect(added.name, 'New project');
        final checkout = added.checkouts.single;
        final agent = checkout.agents.singleWhere(
          (a) => a.installationId == fakeAgentInstallationId,
        );
        final workspace = await client.listWorkspace();
        expect(
          workspace.map((p) => p.projectId),
          contains(added.projectId),
          reason: 'the store the next list reads',
        );

        final started = await client.startSession(
          requestId: 'live-start-2',
          repositoryId: checkout.repositoryId,
          installationId: agent.installationId,
          permissionMode: agent.defaultMode,
          title: 'Started from the phone',
        );
        final sessionId = started.sessionId;
        final running = await readUntil(
          client.listSessions,
          (sessions) => sessions.any(
            (s) => s.sessionId == sessionId && s.status == 'running',
          ),
        );
        final row = running.singleWhere((s) => s.sessionId == sessionId);
        expect(row.title, 'Started from the phone');
        expect(row.projectName, 'New project');
        final first = await readUntil(
          () => client.transcript(sessionId),
          (page) => page.messages.any((m) => m.text.contains('FAKE-AGENT')),
        );
        expect(
          first.messages.last.text,
          contains('--session-id\n$sessionId'),
          reason: 'launched by the adapter\'s own command line',
        );

        // The agent ends on its own: one line typed from the phone.
        await client.sendPrompt(sessionId, 'goodbye');
        final ended = await readUntil(
          client.listSessions,
          (sessions) => sessions.any(
            (s) => s.sessionId == sessionId && s.status == 'completed',
          ),
        );
        expect(
          ended.singleWhere((s) => s.sessionId == sessionId).status,
          'completed',
        );

        // Claude Code's store holds the conversation the row named at launch.
        final bucket = Directory('${home.path}/.claude/projects/live')
          ..createSync(recursive: true);
        File('${bucket.path}/$sessionId.jsonl').writeAsStringSync('{}\n');
        final resumed = await client.resumeSession(
          requestId: 'live-resume',
          sessionId: sessionId,
        );
        expect(resumed.sessionId, sessionId, reason: 'the same row, continued');
        await readUntil(
          client.listSessions,
          (sessions) => sessions.any(
            (s) => s.sessionId == sessionId && s.status == 'running',
          ),
        );
        final again = await readUntil(
          () => client.transcript(sessionId),
          (page) =>
              page.messages.any((m) => m.text.contains('--resume\n$sessionId')),
        );
        expect(
          again.messages.last.text,
          allOf(
            contains('--resume\n$sessionId'),
            isNot(contains('--session-id')),
          ),
          reason: 'the adapter\'s resume, in a new hosted PTY',
        );
        expect(host.output, isNot(contains('Unhandled exception')));
      },
    );
  });

  group('with a desktop attached (slice 5c: nothing is forwarded)', () {
    test(
      'a desktop coming and going changes nothing a phone is told',
      () async {
        final client = await dial(phone);
        final before = (await client.listSessions())
            .map((s) => s.sessionId)
            .toSet();
        expect(before, contains(seededSessionId));

        final desktop = await AppLink.connect(host.socketPath, asApp: true);
        final withDesktop = (await client.listSessions())
            .map((s) => s.sessionId)
            .toSet();
        expect(
          withDesktop,
          before,
          reason: 'the server answers, not a desktop',
        );
        final workspace = await client.listWorkspace();
        expect(workspace, isA<List<RemoteWorkspaceProject>>());

        await desktop.close();
        final after = (await client.listSessions())
            .map((s) => s.sessionId)
            .toSet();
        expect(after, before);
        expect(host.output, isNot(contains('Unhandled exception')));
      },
    );
  });
}
