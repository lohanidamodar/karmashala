import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/mcp/mcp_tool_relay.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:karmashala_host/src/serve/server_features.dart';
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

class _Tool extends ServerToolSet {
  @override
  List<Map<String, Object?>> get schemas => const [
    {'name': 'session_send'},
    {'name': 'device_tap'},
  ];

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) async => 'ran';
}

/// "Let new sessions operate Karmashala": the server's own setting, applied
/// to a row when it is inserted. A client never supplies it.
void main() {
  final at = DateTime.utc(2026, 11, 2, 12);

  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    service = DataService(db, clock: () => at);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    db.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'local', '/src/shop', '$at'],
    );
    db.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', 'claudeCode', 'local', '/bin/claude', '$at', 1],
    );
  });

  tearDown(() => db.close());

  Session row(String id, {bool granted = false}) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work',
    useWorktree: false,
    status: SessionStatus.created,
    createdAt: at,
    operatorGranted: granted,
  );

  Session create(String id, {bool granted = false}) =>
      app.handle(SessionCreate(row(id, granted: granted))).value;

  void set(bool enabled) =>
      app.handle(SessionsOperateByDefaultSet(enabled: enabled));

  Session stored(String id) => SessionDao(db).getById(id)!;

  group('the setting', () {
    test('is off on a new install', () {
      expect(create('s1').operatorGranted, isFalse);
    });

    test('gives a new row the grant while it is on', () {
      set(true);
      expect(create('s1').operatorGranted, isTrue);
      expect(stored('s1').operatorGranted, isTrue);
    });

    test('a client cannot supply the grant', () {
      expect(create('s1', granted: true).operatorGranted, isFalse);
      expect(stored('s1').operatorGranted, isFalse);
    });

    test('a client cannot refuse it either', () {
      set(true);
      expect(create('s1', granted: false).operatorGranted, isTrue);
    });

    test('leaves existing sessions as they are, either way', () {
      create('without');
      set(true);
      create('with');
      expect(stored('without').operatorGranted, isFalse);
      set(false);
      expect(stored('with').operatorGranted, isTrue);
    });

    test('a session can be switched off on its own', () {
      set(true);
      create('s1');
      app.handle(SessionEdit('s1', SessionPatch.operator(granted: false)));
      expect(stored('s1').operatorGranted, isFalse);
    });

    test('is told to every other client', () {
      set(true);
      expect(
        told.expand((batch) => batch.changes),
        contains(
          isA<OperateByDefaultChanged>().having(
            (change) => change.enabled,
            'enabled',
            isTrue,
          ),
        ),
      );
    });

    test('greets a client that subscribes while it is on', () {
      final greeted = <DataChanges>[];
      service.open(greeted.add).handle(const DataSubscribe());
      expect(greeted, isEmpty);

      set(true);
      service.open(greeted.add).handle(const DataSubscribe());
      expect(
        greeted.expand((batch) => batch.changes),
        contains(isA<OperateByDefaultChanged>()),
      );
    });

    test('survives a restart of the service', () {
      set(true);
      final again = DataService(db, clock: () => at).open((_) {});
      final made = again.handle(SessionCreate(row('s1'))).value;
      expect(made.operatorGranted, isTrue);
    });
  });

  group('who may change it', () {
    const request = SessionsOperateByDefaultSet(enabled: true);

    test('it is not a preference a client can write', () {
      expect(
        () => app.handle(PreferenceSet(kOperateNewSessionsKey, 'true')),
        throwsA(
          isA<DataRefused>().having(
            (refusal) => refusal.code,
            'code',
            DataRefusalCode.reserved,
          ),
        ),
      );
    });

    test('a phone needs what starting a session needs', () {
      expect(
        phoneRefusal(request, grants: CapabilitySet.none),
        contains('start_session'),
      );
      expect(
        phoneRefusal(
          request,
          grants: CapabilitySet.of([Capability.startSession]),
        ),
        isNull,
      );
    });
  });

  test('the wire carries it, and the server announces it', () {
    final decoded = DataRequest.fromJson(
      SessionsOperateByDefaultSet.name,
      const SessionsOperateByDefaultSet(enabled: true).argumentsToJson(),
    );
    expect(decoded, isA<SessionsOperateByDefaultSet>());
    expect((decoded as SessionsOperateByDefaultSet).enabled, isTrue);
    expect(
      DataChange.fromJson(
        const OperateByDefaultChanged(enabled: true).toJson(),
      ),
      isA<OperateByDefaultChanged>(),
    );
    expect(kServerFeatures, contains(SessionsOperateByDefaultSet.feature));
  });

  // Acceptance 0, through the real relay and the real rows.
  group('with the relay', () {
    late McpToolRelay relay;

    setUp(() {
      final rows = SessionDao(db);
      relay = McpToolRelay(
        tools: ServerTools([_Tool()]),
        operatorGranted: (id) => rows.getById(id)?.operatorGranted ?? false,
      );
    });

    test(
      'without the grant a session drives a device, not a session',
      () async {
        create('s1');
        expect(await relay.call('device_tap', const {}, 's1'), 'ran');
        await expectLater(
          relay.call('session_send', const {}, 's1'),
          throwsA(isA<McpToolRelayFailure>()),
        );
      },
    );

    test('with the setting on a new session has the grant, can lose it, and '
        'an older session stays refused', () async {
      create('old');
      set(true);
      create('new');
      expect(await relay.call('session_send', const {}, 'new'), 'ran');

      app.handle(SessionEdit('new', SessionPatch.operator(granted: false)));
      await expectLater(
        relay.call('session_send', const {}, 'new'),
        throwsA(isA<McpToolRelayFailure>()),
      );
      await expectLater(
        relay.call('session_send', const {}, 'old'),
        throwsA(isA<McpToolRelayFailure>()),
      );
    });
  });
}
