@Tags(['live'])
library;

import 'dart:io';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
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

    // The app: config on the link, a pairing window, then gone.
    final app = await AppLink.connect(
      host.socketPath,
      config: const CompanionConfig(enabled: true),
    );
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

    test('what only the app can do says the app is not running', () async {
      final client = await dial(phone);

      await expectLater(
        client.listWorkspace(),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.message,
            'message',
            kCompanionAppNotRunning,
          ),
        ),
      );
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
            kCompanionAppNotRunning,
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

  group('with the app back', () {
    test('the app hanging up mid-call does not take the host down', () async {
      final client = await dial(phone);
      // A request makes the phone live, so the app's arrival re-sweeps it.
      await client.listSessions();

      final app = await AppLink.connect(
        host.socketPath,
        config: const CompanionConfig(enabled: true),
      );
      final sweep = await app.nextCall(CompanionMethod.listSessions.wire);
      expect(sweep.method, CompanionMethod.listSessions.wire);
      // Gone without answering, as an app that quits mid-sweep is.
      await app.close();

      final sessions = await client.listSessions();
      expect(
        sessions.map((s) => s.sessionId),
        contains(seededSessionId),
        reason: 'the host is still here, answering from the store',
      );
      expect(host.output, isNot(contains('Unhandled exception')));
    });

    test(
      'what the host cannot answer is the app\'s, news from it included',
      () async {
        final app = await AppLink.connect(
          host.socketPath,
          config: const CompanionConfig(enabled: true),
        );
        addTearDown(app.close);
        // The app's own view, whenever the host re-sweeps phones.
        app
          ..answerAlways(CompanionMethod.listSessions.wire, {'sessions': []})
          ..answerAlways(CompanionMethod.sessionById.wire, {'session': null})
          ..answerAlways(CompanionMethod.deliveryStage.wire, {'stage': null});
        final client = await dial(phone);

        // The config frame and the phone's call travel on two sockets; until
        // the config lands the host answers "not running", so ask again until
        // a call is held open for the app instead.
        late Future<List<RemoteWorkspaceProject>> listing;
        for (var attempt = 0; ; attempt++) {
          listing = client.listWorkspace();
          final refused = await listing
              .then<bool>(
                (_) => false,
                onError: (Object e) =>
                    e is RemoteApiException &&
                        e.message == kCompanionAppNotRunning &&
                        attempt < 20
                    ? true
                    : throw e,
              )
              .timeout(const Duration(seconds: 1), onTimeout: () => false);
          if (!refused) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        Future<void> answerWorkspace(String name) async {
          final call = await app.nextCall(CompanionMethod.listWorkspace.wire);
          app.answer(call.callId, {
            'projects': [
              RemoteWorkspaceProject(
                projectId: 'app-$name',
                name: name,
              ).toJson(),
            ],
          });
        }

        await answerWorkspace('From the app');
        final projects = await listing;
        expect(projects.single.projectId, 'app-From the app');
        expect(projects.single.name, 'From the app');

        // A phone that has listed sessions is swept for new ones. Sessions
        // then move on the desktop, as it says on every change: the host
        // re-sweeps by asking this same link for its list, and must go on
        // reading this link's frames while it waits for that answer.
        expect(await client.listSessions(), isEmpty, reason: 'the app\'s view');
        app.notice(
          const CompanionNoticeMessage(CompanionNoticeKind.sessionsMoved),
        );
        final again = client.listWorkspace();
        await answerWorkspace('Still the app');
        expect((await again).single.name, 'Still the app');
      },
    );
  });
}
