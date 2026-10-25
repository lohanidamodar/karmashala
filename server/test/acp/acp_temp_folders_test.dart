import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/acp/acp_temp_folders.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// What a killed agent leaves in TEMP is removed — only folders that are
/// Karmashala's own or carry Antigravity's marker, and never one a running
/// process holds.
void main() {
  late Directory base;
  late String own;
  late String shared;

  setUp(() {
    base = Directory.systemTemp.createTempSync('acp_temp_sweep');
    own = p.join(base.path, 'own');
    shared = p.join(base.path, 'shared');
    Directory(own).createSync();
    Directory(shared).createSync();
  });
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  Directory folder(String root, String name, Map<String, int> files) {
    final directory = Directory(p.join(root, name))..createSync();
    for (final MapEntry(:key, :value) in files.entries) {
      File(p.join(directory.path, key))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(value, 1));
    }
    return directory;
  }

  test('only marker folders in the shared TEMP are removed', () async {
    final agy = folder(shared, '_MEI1234', {
      kAntigravityAcpMarker: 10,
      'lib/python.dll': 90,
    });
    final other = folder(shared, '_MEI9999', {'base_library.zip': 50});
    final unrelated = folder(shared, 'something', {kAntigravityAcpMarker: 5});

    final swept = await sweepAcpTempFoldersApart(
      ownRoot: own,
      systemTemp: shared,
    );

    expect(agy.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
    expect(swept.removed, [agy.path]);
    expect(swept.bytesFreed, 100);
  });

  test('every folder of its own is removed, but not a live one', () async {
    final left = folder(own, 'a1', {'x': 7});
    final live = folder(own, 'a2', const {});

    final swept = await sweepAcpTempFolders(ownRoot: own, keep: {live.path});

    expect(left.existsSync(), isFalse);
    expect(live.existsSync(), isTrue);
    expect(swept.removed, [left.path]);
  });

  test('a folder a running process holds is left whole', () async {
    final held = folder(shared, '_MEI4242', {
      kAntigravityAcpMarker: 10,
      'agent.bin': 20,
    });
    // An open file holds it, as a running agent holds its unpacked DLLs.
    final open = await File(p.join(held.path, 'agent.bin')).open();
    addTearDown(open.close);

    final swept = await sweepAcpTempFolders(ownRoot: own, systemTemp: shared);

    expect(swept.held, [held.path]);
    expect(swept.removed, isEmpty);
    expect(File(p.join(held.path, 'agent.bin')).existsSync(), isTrue);
    expect(File(p.join(held.path, kAntigravityAcpMarker)).existsSync(), isTrue);
  }, skip: Platform.isWindows ? false : 'the rename refusal is Windows only');

  test('a launch gets its own TEMP, removed once it has exited', () async {
    final temp = AcpTempFolders(own);
    final process = FakeProcessHandle();
    final runner = FakeCommandRunner(processFactory: (_) => process);

    await startAcpProcess(
      runner.start,
      const CommandRequest(executable: 'agy', environment: {'A': '1'}),
      temp: temp,
    );

    final variables = runner.startRequests.single.environment;
    final folder = variables['TEMP']!;
    expect(variables['TMP'], folder);
    expect(variables['A'], '1');
    expect(p.isWithin(own, folder), isTrue);
    expect(Directory(folder).existsSync(), isTrue);
    expect(temp.live, {folder});
    File(p.join(folder, 'unpacked.bin')).writeAsStringSync('x');

    process.complete(0);
    for (var i = 0; i < 50 && Directory(folder).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(Directory(folder).existsSync(), isFalse);
    expect(temp.live, isEmpty);
  });

  test('a start that fails leaves no folder', () async {
    final temp = AcpTempFolders(own);
    final runner = FakeCommandRunner(throwError: StateError('no agy'));
    await expectLater(
      startAcpProcess(
        runner.start,
        const CommandRequest(executable: 'agy'),
        temp: temp,
      ),
      throwsStateError,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(Directory(own).listSync(), isEmpty);
  });

  test('only a Windows host and its own agents get one', () {
    final temp = AcpTempFolders(own);
    final wsl = ExecutionEnvironment(
      id: 'wsl:Ubuntu',
      kind: EnvironmentKind.wsl,
      name: 'Ubuntu',
      wslDistribution: 'Ubuntu',
      createdAt: DateTime.utc(2026),
    );
    expect(temp.forEnvironment(wsl), isNull);
    expect(temp.forEnvironment(null), Platform.isWindows ? temp : isNull);
  });

  test('each data folder has its own short root under TEMP', () {
    final a = AcpTempFolders.forDataDirectory(
      r'C:\a\very\long\data',
      tempBase: own,
    );
    final b = AcpTempFolders.forDataDirectory(r'C:\other', tempBase: own);
    expect(a.root, isNot(b.root));
    expect(p.dirname(a.root), p.join(own, 'ks-acp'));
    expect(p.basename(a.root), hasLength(8));
    expect(
      AcpTempFolders.forDataDirectory(
        r'C:\A\Very\Long\Data',
        tempBase: own,
      ).root,
      a.root,
    );
  });
}
