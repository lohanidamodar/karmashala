import 'dart:io';

import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionPromptKindsChanged;
import 'package:karmashala_host/src/acp/acp_session_modes.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// Whether the agent takes images in a prompt (`promptCapabilities.image`)
/// is told to every client once it has started, greeted to one that arrives
/// later, and gone with the agent.
void main() {
  late AppDatabase database;
  late Directory temp;
  late _KindsHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_prompt_kinds');
    host = _KindsHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  for (final images in [true, false]) {
    test('an agent ${images ? 'that takes' : 'that takes no'} images says so',
        () async {
      final process = FakeAcpProcess(FakeAcpAgent(supportsImages: images));
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: temp.path,
        host: host,
      );
      await runtime.start();

      expect(host.kinds.single.sessionId, 's1');
      expect(host.kinds.single.images, images);
      final greeted = AcpSessionModes(
        runtimeOf: (_) => runtime,
        running: () => [runtime],
      ).greeting().whereType<SessionPromptKindsChanged>().single;
      expect(greeted.images, images);

      await runtime.stop();
      expect(host.kinds.last.images, isFalse, reason: 'the agent is gone');
    });
  }
}

class _KindsHost extends RecordingHost {
  final kinds = <SessionPromptKindsChanged>[];

  @override
  void promptKindsChanged(SessionPromptKindsChanged change) =>
      kinds.add(change);
}
