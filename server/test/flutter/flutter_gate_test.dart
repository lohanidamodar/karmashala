import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_verification/store.dart' show VerificationDao;
import 'package:karmashala_verification/verification.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'flutter_fixture.dart';

void main() {
  late FlutterFixture fixture;

  setUp(() => fixture = FlutterFixture());
  tearDown(() => fixture.close());

  List<VerificationRun> recorded() =>
      VerificationDao(fixture.database).listRuns(limit: 50);

  Future<void> exitWith(int code, {String printed = ''}) async {
    if (printed.isNotEmpty) fixture.lastProcess.emit(utf8.encode(printed));
    fixture.lastProcess.finish(code);
    await settle();
    await fixture.work.loop.drain();
  }

  test('analyze runs the located SDK in the checkout', () async {
    final outcome = await fixture.work.loop.gate(
      wslProject,
      FlutterCommandKind.analyze,
      extraArguments: const ['--fatal-infos'],
    );
    expect(outcome.preflight.isClear, isTrue);
    final argv = fixture.pty.started.single.argv;
    expect(argv.sublist(argv.length - 3), [
      '/home/me/flutter/bin/flutter',
      'analyze',
      '--fatal-infos',
    ]);
    expect(
      fixture.told.whereType<HostedRunChanged>().single.run.title,
      'analyze · demo',
    );
  });

  test('a green gate becomes a recorded pass, told to clients', () async {
    final outcome = await fixture.work.loop.gate(
      wslProject,
      FlutterCommandKind.analyze,
      sessionId: 's1',
    );
    await exitWith(0, printed: 'No issues found! (ran in 9.1s)\r\n');
    final run = recorded().single;
    expect(run.verdict, VerificationVerdict.pass);
    expect(run.title, 'flutter analyze · /home/me/app');
    expect(run.producedBySessionId, 's1');
    final loopRun = fixture.work.loop.byPane(outcome.run!.paneId)!;
    expect(loopRun.verificationRunId, run.id);
    expect(loopRun.exitCode, 0);
    expect(fixture.told.whereType<VerificationRunChanged>(), isNotEmpty);
  });

  test('a failing gate records the fail and keeps what it printed', () async {
    await fixture.work.loop.gate(wslProject, FlutterCommandKind.test);
    await exitWith(1, printed: '00:12 +41 -1: Some tests failed.\r\n');
    final run = VerificationDao(fixture.database).getRun(recorded().single.id)!;
    expect(run.verdict, VerificationVerdict.fail);
    expect(run.reason, contains('exited 1'));
    final artifact = File(
      p.join(run.artifactDirectory, run.artifacts.single.relativePath),
    );
    expect(artifact.readAsStringSync(), contains('Some tests failed'));
  });

  test('pub get and run are not checks and record nothing', () async {
    final outcome = await fixture.work.loop.pubGet(wslProject);
    await exitWith(0);
    expect(recorded(), isEmpty);
    expect(fixture.work.loop.byPane(outcome.run!.paneId)!.exitCode, 0);
  });

  test('a second gate of the same kind while one is live is refused', () async {
    final loop = fixture.work.loop;
    final first = await loop.gate(wslProject, FlutterCommandKind.analyze);
    final second = await loop.gate(wslProject, FlutterCommandKind.analyze);
    expect(second.run, isNull);
    expect(second.preflight.problem, FlutterPreflightProblem.alreadyRunning);
    expect(second.preflight.reason, contains(first.run!.paneId));
    final other = await loop.gate(wslProject, FlutterCommandKind.test);
    expect(other.run, isNotNull, reason: 'analyze and test do not block');
  });

  test('a verdict that could not be written does not stop the next', () async {
    final artifacts = Directory(p.join(fixture.root.path, 'verification'));
    if (artifacts.existsSync()) artifacts.deleteSync(recursive: true);
    File(artifacts.path).writeAsStringSync('not a directory');
    await fixture.work.loop.gate(wslProject, FlutterCommandKind.analyze);
    await exitWith(1);
    expect(recorded(), isEmpty);

    File(artifacts.path).deleteSync();
    await fixture.work.loop.gate(wslProject, FlutterCommandKind.test);
    await exitWith(0);
    expect(recorded().single.verdict, VerificationVerdict.pass);
  });
}
