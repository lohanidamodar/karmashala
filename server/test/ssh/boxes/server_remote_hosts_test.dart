import 'dart:convert';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/ssh/boxes/box_screen.dart';
import 'package:karmashala_host/src/ssh/ssh_domain.dart';
import 'package:test/test.dart';

import '../support/box_world.dart';

/// The server's link to the host on an SSH box (slice 5d), against a box in
/// this process: the host deployed, a session started there and its screen
/// kept here, its exit the box's own fact, a second start adopted, the
/// sessions kept by the box across the server restarting, and a box that
/// cannot run the host refused in words — never a fallback.
void main() {
  late BoxWorld world;

  setUp(() => world = BoxWorld());
  tearDown(() => world.close());

  test('a shell opens on the box in the user\'s login shell, and its screen '
      'is read here', () async {
    final opened = await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_local_p1',
      workingDirectory: '/home/dev/src',
      columns: 100,
      rows: 30,
    );
    expect(opened.adopted, isFalse);
    expect(world.box.ptys, hasLength(1));
    final started = world.box.ptys.single.request;
    expect(started.argv, ['/bin/bash', '-l']);
    expect(started.workingDirectory, '/home/dev/src');
    expect(started.environment['TERM'], 'xterm-256color');
    expect((started.columns, started.rows), (100, 30));
    // Deployed first: the bundle uploaded and unpacked under the box's home.
    expect(
      world.box.uploads.single,
      '/home/dev/.karmashala/bin/karmashala_host-1.25.0-linux-x64.tar.gz',
    );

    world.box.ptys.single.emit(utf8.encode('\x1b]0;build\x07hello box\r\n'));
    await until(() => opened.session.tailText(5).contains('hello box'));
    expect(opened.session.tailText(5), contains('hello box'));
    expect(opened.session.facts?.title, 'build');
    expect(opened.session.ref, 'ssh:h1/karmashala_local_p1');
    expect(world.ssh.remote.byId('karmashala_local_p1'), same(opened.session));
  });

  test('its exit is the box\'s: the code, told as a lifecycle event', () async {
    final events = <LifecycleEvent>[];
    world.ssh.onBoxLifecycle = events.add;
    final opened = await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_row1',
      argv: const ['claude', '--resume', 'c1'],
      columns: 80,
      rows: 24,
    );
    world.box.ptys.single.finish(3);
    final end = await opened.session.ended.timeout(const Duration(seconds: 5));
    expect(end.exitCode, 3);
    await until(() => events.any((e) => e.kind == LifecycleEventKind.exited));
    final exited = events.firstWhere(
      (e) => e.kind == LifecycleEventKind.exited,
    );
    expect(exited.sessionId, 'karmashala_row1');
    expect(exited.exitCode, 3);
  });

  test('a second start of the same session is adopted: nothing starts '
      'twice', () async {
    await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_local_p1',
      columns: 80,
      rows: 24,
    );
    final again = await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_local_p1',
      columns: 80,
      rows: 24,
    );
    expect(again.adopted, isTrue);
    expect(world.box.ptys, hasLength(1));
  });

  test('the box keeps its sessions across the server restarting: a new '
      'server keeps a copy of each again', () async {
    await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_row1',
      argv: const ['codex'],
      columns: 80,
      rows: 24,
    );
    world.box.ptys.single.emit(utf8.encode('before the restart\r\n'));
    await settle();
    // The first server goes; the box and its host stay.
    await world.ssh.close();
    final second = ServerSshDomain(
      data: world.data,
      database: world.db,
      dataDirectory: '/nonexistent-data-dir',
      bundles: FakeBundles(),
      targetFor: (_) => world.box,
    );
    addTearDown(second.close);
    expect(await second.adoptRunning(BoxWorld.hostId), 1);
    final kept = second.remote.byId('karmashala_row1')!;
    await until(() => kept.tailText(5).contains('before the restart'));
    expect(kept.tailText(5), contains('before the restart'));
    world.box.ptys.single.emit(utf8.encode('after it\r\n'));
    await until(() => kept.tailText(5).contains('after it'));
    expect(kept.lifecycle.hasEnded, isFalse);
  });

  test('a link that drops is made again, and the copy resumes where it '
      'stopped', () async {
    final opened = await world.ssh.remote.open(
      world.environment,
      sessionId: 'karmashala_local_p1',
      columns: 80,
      rows: 24,
    );
    await world.box.dropLinks();
    await until(() => !(opened.session as BoxScreen).linked);
    world.box.ptys.single.emit(utf8.encode('while away\r\n'));
    // The relink waits a second first.
    await until(
      () => opened.session.tailText(5).contains('while away'),
      tries: 600,
    );
    expect(opened.session.tailText(5), contains('while away'));
  });

  test('a musl box is refused in words, and nothing is put on it', () async {
    world.box.uname = 'Linux\nx86_64\nmusl libc (x86_64)\n';
    await expectLater(
      world.ssh.remote.open(
        world.environment,
        sessionId: 'karmashala_local_p1',
        columns: 80,
        rows: 24,
      ),
      throwsA(
        isA<RemoteSessionRefused>().having(
          (e) => e.message,
          'message',
          allOf(contains('musl'), contains('glibc Linux and macOS only')),
        ),
      ),
    );
    expect(world.box.uploads, isEmpty);
    expect(world.box.ptys, isEmpty);
  });

  test('a box with no bundle on the server is refused, naming where the '
      'server looked', () async {
    final none = BoxWorld(bundles: FakeBundles(const []));
    addTearDown(none.close);
    await expectLater(
      none.ssh.remote.open(
        none.environment,
        sessionId: 'karmashala_local_p1',
        columns: 80,
        rows: 24,
      ),
      throwsA(
        isA<RemoteSessionRefused>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('linux-x64'),
            contains('/srv/karmashala/host-bundles'),
          ),
        ),
      ),
    );
  });

  test('a bundle put on the server after a refusal is deployed by the Retry, '
      'on the same connection', () async {
    final targets = <String>[];
    final later = BoxWorld(bundles: FakeBundles(targets));
    addTearDown(later.close);
    Future<Object> open() => later.ssh.remote.open(
      later.environment,
      sessionId: 'karmashala_local_p1',
      columns: 80,
      rows: 24,
    );
    await expectLater(open(), throwsA(isA<RemoteSessionRefused>()));

    targets.add('linux-x64');
    await open();
    expect(later.box.uploads, hasLength(1));
    expect(later.box.ptys, hasLength(1));
  });

  test('a probe\'s server uses no box\'s host at all', () async {
    final probe = BoxWorld(probe: true);
    addTearDown(probe.close);
    expect(probe.ssh.remote.reaches(probe.environment), isFalse);
    await expectLater(
      probe.ssh.remote.open(
        probe.environment,
        sessionId: 'karmashala_local_p1',
        columns: 80,
        rows: 24,
      ),
      throwsA(
        isA<RemoteSessionRefused>().having(
          (e) => e.message,
          'message',
          contains('owner'),
        ),
      ),
    );
    expect(probe.box.commands, isEmpty);
  });
}
