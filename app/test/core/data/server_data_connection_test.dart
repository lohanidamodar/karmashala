import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/server_data_connection.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

/// The data link and the supervisor that keeps the server up, tied together.
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('karmashala_data_'));
  tearDown(() => removeTempDirectory(home));

  // Found live: the host's binary was hidden, the supervisor stopped at once
  // (no binary), and when the binary came back nothing started the server
  // although the data client kept redialling. Each redial that finds nobody
  // now nudges the supervisor, which looks for the binary again.
  test('a redial that finds no server nudges a supervisor stopped for want '
      'of a binary into looking again', () async {
    final server = FakeDataServer(projects: {});
    final client = await server.connect();
    final access = LocalHostSessionAccess(
      paths: HostPaths(Directory('${home.path}/host')..createSync()),
      executable: LocalHostExecutable(
        executableDirectory: home.path,
        repositoryRoot: home.path,
      ),
      startServe: (_) => throw StateError('nothing is started here'),
    );
    final supervisor = LocalHostSupervisor(
      access: access,
      noBinaryRecheck: const Duration(hours: 1),
      nudgeFloor: Duration.zero,
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    expect(supervisor.state.phase, HostSupervisionPhase.stopped);

    final undo = superviseDataLink(client, supervisor);
    addTearDown(undo);
    final looked = supervisor.changes
        .where((s) => s.phase == HostSupervisionPhase.stopped)
        .first;

    server.stop();
    await client.connectionChanges
        .firstWhere((c) => c.state == DataLinkState.unavailable)
        .timeout(const Duration(seconds: 5));
    final look = await looked.timeout(const Duration(seconds: 5));
    expect(look.reason, contains('No karmashala_host'));
  });
}
