import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/data/store_scan_worker.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:agent_cli/read.dart';

/// **What a brand-new session sets in motion after it has started.**
///
/// A start is not over when `SessionLauncher.launch` returns. By construction
/// the row it wrote is *waiting for its CLI's name*, and three services wake on
/// the status registry's store slot when such a row exists:
/// `SessionAdoptionService`, `LaunchedSessionAttributionService` and
/// `SessionTitleSyncService`. `cliStoreSyncRunnerProvider` is the one line the
/// slot runs, and the slot comes round every
/// `kTranscriptSearchInterval` — ten seconds — for as long as the app is open.
///
/// So the question this file answers is not "what does the click cost" but
/// "what does the click sign the app up for". Counted in the two units that
/// decide it:
///
/// * **requests to the server**, because each is a round trip the slot waits
///   on (the app opens no database of its own); and
/// * **store bytes**, because the scan is the disk work — measured on the
///   owner's machine at 2.4 GB across 540 files per pass before
///   `claude_store_scan_cost_test.dart`'s incremental read.
///
/// Both are read as a *delta*: the same workspace is run twice, once with every
/// session named by its user and once with one brand-new row added, and the
/// difference is what the new session bought. That is the only honest way to
/// price it — a workspace with a running session is never free, and the
/// question is what *one more* costs.
void main() {
  late Directory tmp;
  late String storeHome;

  /// Conversation files in the store. Small enough to run anywhere, large
  /// enough that re-reading them instead of stat-ing them is visible.
  const conversations = 12;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_slot_cost_');
    storeHome = p.join(tmp.path, '.claude');
    Directory(
      p.join(storeHome, 'projects', '-repo'),
    ).createSync(recursive: true);
    for (var i = 0; i < conversations; i++) {
      _writeConversation(storeHome, _conversationId(i), 'Conversation $i');
    }
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file a failing test left open.
    }
  });

  /// A workspace of [named] sessions the user has titled, plus [waiting]
  /// brand-new ones — a row still wearing `ExplorerActions.startSession`'s
  /// "New session", which is exactly what the `+` leaves behind.
  Future<_Slot> slot({required int named, int waiting = 0}) async {
    final server = FakeDataServer();
    void insertSession({
      required String id,
      required String title,
      required String conversation,
      bool titleByUser = false,
    }) => server.sessionRows.insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: title,
        useWorktree: false,
        workingDirectory: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: conversation,
        titleByUser: titleByUser,
      ),
    );
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    for (var i = 0; i < named; i++) {
      insertSession(
        id: 's$i',
        title: 'What I called it $i',
        conversation: _conversationId(i % conversations),
        titleByUser: true,
      );
    }
    for (var i = 0; i < waiting; i++) {
      insertSession(
        id: 'new$i',
        // The launcher mints our own id and hands it to `--session-id`, so a
        // brand-new Claude row already knows its conversation. What it does
        // not have is a name.
        conversation: _conversationId((named + i) % conversations),
        title: 'New session',
      );
    }
    final detection = _CountingDetection();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        cliDetectionServiceProvider.overrideWithValue(detection),
        // The stores are read through the scan runner now; inline here, so the
        // pass is counted on this isolate rather than on a worker.
        storeScanRunnerProvider.overrideWithValue(
          InlineStoreScanRunner(detection: detection),
        ),
        cliStoreLocatorProvider.overrideWithValue(
          FixedLocator([
            CliStore(
              environmentId: 'windows',
              homesByAgentId: {AgentIds.claudeCode: storeHome},
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    return _Slot(container, server, detection);
  }

  group('the store slot', () {
    test('costs nothing extra while every session has a name', () async {
      final quiet = await slot(named: 20);
      await quiet.run();

      final measured = await quiet.run();

      // ignore: avoid_print
      print(
        'STORE-SLOT waiting=0 requests=${measured.requests.length} '
        'scans=${measured.scans} bytes=${measured.bytes}',
      );
      expect(
        measured.scans,
        0,
        reason:
            'a workspace whose sessions all carry names the user chose has '
            'nothing to learn from a store, so it must not open one',
      );
      expect(measured.bytes, 0);
    });

    test(
      'a brand-new session buys one scan, shared by its passengers',
      () async {
        final busy = await slot(named: 20, waiting: 1);
        await busy.run();

        final measured = await busy.run();

        // ignore: avoid_print
        print(
          'STORE-SLOT waiting=1 requests=${measured.requests.length} '
          'scans=${measured.scans} bytes=${measured.bytes}',
        );
        expect(
          measured.scans,
          1,
          reason:
              'attribution and the title sync ask the disk the same question, '
              'and `cliStoreScanPassProvider` exists so one slot reads it once',
        );
        expect(
          measured.bytes,
          0,
          reason:
              'nothing in the store moved between the two slots, so a stat is '
              'the whole of the second one — the incremental read '
              '`claude_store_scan_cost_test.dart` pins',
        );
      },
    );

    test('and the scan it buys does not grow with the workspace', () async {
      final requests = <int, int>{};
      final scans = <int, int>{};
      for (final count in const [1, 10, 100]) {
        final busy = await slot(named: count, waiting: 1);
        await busy.run();

        final measured = await busy.run();
        requests[count] = measured.requests.length;
        scans[count] = measured.scans;
        // ignore: avoid_print
        print(
          'STORE-SLOT sessions=$count waiting=1 '
          'requests=${measured.requests.length} '
          'scans=${measured.scans} '
          'bytes=${measured.bytes}',
        );
      }

      expect(
        scans.values.toSet(),
        orderedEquals([1]),
        reason: 'one store scan per slot, whatever is open: $scans',
      );
      expect(
        requests.values.toSet(),
        hasLength(1),
        reason:
            'a slot asks the server a fixed number of questions; nothing on '
            'it may ask one per row: $requests',
      );
    });

    test('a name the CLI wrote lands on the row, once', () async {
      final busy = await slot(named: 2, waiting: 1);

      await busy.run();

      expect(
        busy.server.sessionRows.getById('new0')!.title,
        'Conversation 2',
        reason: 'the whole point of the slot: the CLI names the session',
      );

      // And a slot that renamed nothing writes nothing.
      final measured = await busy.run();
      expect(
        measured.writes,
        isEmpty,
        reason: 'a second slot over an unchanged store: ${measured.writes}',
      );
    });
  });
}

String _conversationId(int i) =>
    'aaaaaaaa-bbbb-4ccc-8ddd-${i.toString().padLeft(12, '0')}';

/// A conversation file with a title and enough bulk that re-reading it instead
/// of stat-ing it would show up in the byte count.
void _writeConversation(String home, String id, String title) {
  File(p.join(home, 'projects', '-repo', '$id.jsonl')).writeAsStringSync(
    [
      _line({'type': 'user', 'cwd': r'C:\src\demo\app', 'message': 'start'}),
      // Real assistant turns, not a bare string: the transcript reader only
      // sees a `message` that is an object, and the conversation index is fed
      // by that reader.
      for (var i = 0; i < 200; i++)
        _line({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'padding line $i ' * 8},
            ],
          },
        }),
      _line({'type': 'custom-title', 'customTitle': title}),
    ].join(),
  );
}

String _line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

/// One store slot, and what running it cost.
class _Slot {
  _Slot(this.container, this.server, this.detection);

  final ProviderContainer container;
  final FakeDataServer server;
  final _CountingDetection detection;

  /// Runs one slot — the single line `SessionStatusRegistry.onCycle` runs when
  /// it is allowed to touch the disk — and reports what it cost.
  Future<_SlotCost> run() async {
    await container.read(dataClientProvider).settled();
    final asked = server.requests.length;
    detection.scans = 0;
    final before = detection.claudeReader.bytesRead;

    await container.read(cliStoreSyncRunnerProvider)();
    await container.read(dataClientProvider).settled();

    return _SlotCost(
      requests: server.requests.sublist(asked),
      scans: detection.scans,
      bytes: detection.claudeReader.bytesRead - before,
    );
  }
}

class _SlotCost {
  const _SlotCost({
    required this.requests,
    required this.scans,
    required this.bytes,
  });

  /// Every request the slot sent the server, by kind, in order.
  final List<String> requests;

  /// The ones that write.
  List<String> get writes => [
    for (final kind in requests)
      if (!kind.endsWith('.list') && kind != 'data.subscribe') kind,
  ];

  /// Passes over the CLI stores. Two services want one on the slot a session
  /// learns its name, and `cliStoreScanPassProvider` is why that is one read.
  final int scans;

  /// Bytes lifted off the disk by the Claude store reader.
  final int bytes;
}

/// The production detection service, counting the passes made over it.
///
/// One pass is one call to [jobsFor]: the scan queue asks for the job list
/// once, then runs the jobs it was given.
class _CountingDetection extends CliDetectionService {
  int scans = 0;

  ClaudeStoreReader get claudeReader =>
      readerFor(AgentIds.claudeCode)! as ClaudeStoreReader;

  @override
  List<StoreScanJob> jobsFor(List<CliStore> stores) {
    scans++;
    return super.jobsFor(stores);
  }
}
