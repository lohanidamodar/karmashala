import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/store_scan_worker.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fixtures.dart';
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
/// * **database statements**, because `package:sqlite3` is synchronous and a
///   statement is main-isolate time inside a frame; and
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
  _Slot slot({required int named, int waiting = 0}) {
    final db = _CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
    for (var i = 0; i < named; i++) {
      db.insertSession(
        id: 's$i',
        title: 'What I called it $i',
        conversation: _conversationId(i % conversations),
        titleByUser: true,
      );
    }
    for (var i = 0; i < waiting; i++) {
      db.insertSession(
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
        databaseProvider.overrideWithValue(db),
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
    addTearDown(db.close);
    return _Slot(container, db, detection);
  }

  group('the store slot', () {
    test('costs nothing extra while every session has a name', () async {
      final quiet = slot(named: 20);
      await quiet.run();

      final measured = await quiet.run();

      // ignore: avoid_print
      print(
        'STORE-SLOT waiting=0 statements=${measured.statements.length} '
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
        final busy = slot(named: 20, waiting: 1);
        await busy.run();

        final measured = await busy.run();

        // ignore: avoid_print
        print(
          'STORE-SLOT waiting=1 statements=${measured.statements.length} '
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
      final statements = <int, int>{};
      final scans = <int, int>{};
      for (final count in const [1, 10, 100]) {
        final busy = slot(named: count, waiting: 1);
        await busy.run();

        final measured = await busy.run();
        statements[count] = measured.statements.length;
        scans[count] = measured.scans;
        // ignore: avoid_print
        print(
          'STORE-SLOT sessions=$count waiting=1 '
          'statements=${measured.statements.length} '
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
        statements.values.toSet(),
        hasLength(1),
        reason:
            'a slot reads the session table a fixed number of times; nothing '
            'on it may ask a question per row: $statements',
      );
    });

    test('the conversation the CLI just named is indexed, that slot', () async {
      final busy = slot(named: 2, waiting: 1);

      await busy.run();

      // The rename is the app's existing evidence that the CLI wrote to that
      // conversation's store, and it is one of the two triggers the index is
      // built on. The turns land on the same slot, off the scan the rename
      // already paid for.
      final dao = ConversationIndexDao(busy.db);
      expect(
        dao.search('padding').map((hit) => hit.sessionId),
        contains(_conversationId(2)),
      );
      expect(dao.stateFor(_conversationId(2))!.turns, greaterThan(0));
    });

    test('and a slot with nothing to index never reads the index', () async {
      final busy = slot(named: 2, waiting: 1);
      await busy.run();

      final measured = await busy.run();

      // The second slot: the rename already happened, so nothing is queued and
      // `drain` returns before it touches the database or the disk.
      expect(
        measured.statements.where((sql) => sql.contains('conversation_')),
        isEmpty,
        reason: 'an idle indexer must cost no statement: ${measured.writes}',
      );
    });

    test('a name the CLI wrote lands on the row, once', () async {
      final busy = slot(named: 2, waiting: 1);

      await busy.run();

      expect(
        SessionDao(busy.db).getById('new0')!.title,
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
  _Slot(this.container, this.db, this.detection);

  final ProviderContainer container;
  final _CountingDatabase db;
  final _CountingDetection detection;

  /// Runs one slot — the single line `SessionStatusRegistry.onCycle` runs when
  /// it is allowed to touch the disk — and reports what it cost.
  Future<_SlotCost> run() async {
    db.reset();
    detection.scans = 0;
    final before = detection.claudeReader.bytesRead;

    await container.read(cliStoreSyncRunnerProvider)();

    return _SlotCost(
      statements: List.of(db.statements),
      writes: db.writes,
      scans: detection.scans,
      bytes: detection.claudeReader.bytesRead - before,
    );
  }
}

class _SlotCost {
  const _SlotCost({
    required this.statements,
    required this.writes,
    required this.scans,
    required this.bytes,
  });

  /// Every statement the slot ran, in order.
  final List<String> statements;
  final List<String> writes;

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

  @override
  List<StoreScanJob> jobsFor(List<CliStore> stores) {
    scans++;
    return super.jobsFor(stores);
  }
}

/// An [AppDatabase] that records every statement, so a slot can be priced in
/// main-isolate time.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> statements = [];

  void reset() => statements.clear();

  int get count => statements.length;

  List<String> get writes => statements
      .where((sql) => !sql.trimLeft().toUpperCase().startsWith('SELECT'))
      .toList();

  void insertSession({
    required String id,
    required String title,
    required String conversation,
    bool titleByUser = false,
  }) {
    SessionDao(this).insert(
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
  }

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements.add(sql);
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements.add(sql);
    super.execute(sql, params);
  }
}
