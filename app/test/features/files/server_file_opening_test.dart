/// What this machine's own programs do with a file the server holds (slice
/// 3c): a file on this machine goes to the file manager by the server's own
/// spelling of it; one behind a server elsewhere is brought here first.
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/features/files/application/server_file_opening.dart';
import 'package:karmashala/src/features/files/data/files_client.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

void main() {
  late Directory tmp;
  late FakeDataServer server;
  late FakeCommandRunner host;

  EnvironmentPath here(String name) => EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: p.join(tmp.path, name),
  );

  Future<ServerFileOpening> opening({bool onThisMachine = true}) async {
    final files = FilesClient(
      await server.connect(serverOnThisMachine: onThisMachine),
    );
    addTearDown(files.dispose);
    return ServerFileOpening(
      files,
      RevealInFileManager(
        host: host,
        translator: const PathTranslator(),
        environmentFor: (_) => null,
        fileManagerOverride: HostFileManager.macFinder,
      ),
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-opening-');
    server = FakeDataServer();
    host = FakeCommandRunner();
    File(here('notes.md').path).writeAsStringSync('carry me');
  });

  tearDown(() => removeTempDirectory(tmp));

  test('a file on this machine is revealed by the server\'s own path', () async {
    final open = await opening();

    expect(open.canReveal(here('notes.md')), isTrue);
    final outcome = await open.reveal(here('notes.md'), select: true);

    expect(outcome.ok, isTrue);
    expect(host.requests.single.arguments, ['-R', here('notes.md').path]);
  });

  test('behind a server elsewhere nothing is revealed, and opening brings '
      'the file here first', () async {
    final open = await opening(onThisMachine: false);

    expect(open.canReveal(here('notes.md')), isFalse);
    expect((await open.reveal(here('notes.md'))).ok, isFalse);
    expect(host.requests, isEmpty);

    final outcome = await open.openWithDefaultApp(here('notes.md'));

    expect(outcome.ok, isTrue);
    final opened = host.requests.single.arguments.single;
    expect(opened, isNot(here('notes.md').path));
    expect(p.basename(opened), 'notes.md');
    expect(File(opened).readAsStringSync(), 'carry me');
    addTearDown(() => removeTempDirectory(File(opened).parent));
  });
}
