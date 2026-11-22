import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/serve/server_features.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_remote/remote.dart' show Capability, CapabilitySet;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Agent tool access: kept whole under one server key, changed only through
/// its own request, told to every client and greeted when not the defaults.
void main() {
  final t0 = DateTime.utc(2026, 11, 22, 12);
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  const policy = <String, Object?>{
    'groups': {'answer': true},
    'projects': {
      'p1': {
        'groups': {'message': false},
      },
    },
  };

  List<DataChange> greeting(DataService service) {
    final greeted = <DataChanges>[];
    service.open(greeted.add).handle(const DataSubscribe());
    return [for (final batch in greeted) ...batch.changes];
  }

  test('nothing stored is the defaults, and a subscriber hears nothing', () {
    expect(db.readMetadata(kAgentToolAccessKey), isNull);
    expect(
      greeting(DataService(db, clock: () => t0)),
      isNot(contains(isA<ToolAccessChanged>())),
    );
  });

  test('set through its own method, told to every client, greeted after', () {
    final service = DataService(db, clock: () => t0);
    final told = <DataChanges>[];
    service.open(told.add).handle(const DataSubscribe());
    service.open((_) {}).handle(const AgentsToolAccessSet(policy: policy));

    expect(
      McpToolAccessPolicy.parse(db.readMetadata(kAgentToolAccessKey)),
      McpToolAccessPolicy.fromJson(policy),
    );
    expect(
      told.expand((b) => b.changes),
      contains(
        isA<ToolAccessChanged>().having((c) => c.policy, 'policy', policy),
      ),
    );
    expect(
      greeting(service),
      contains(
        isA<ToolAccessChanged>().having((c) => c.policy, 'policy', policy),
      ),
    );
  });

  test('what it cannot read is dropped before it is kept or told', () {
    final service = DataService(db, clock: () => t0);
    final told = <DataChanges>[];
    service.open(told.add).handle(const DataSubscribe());
    service
        .open((_) {})
        .handle(
          const AgentsToolAccessSet(
            policy: {
              'groups': {'nope': true, 'start': false},
            },
          ),
        );
    final kept = jsonDecode(db.readMetadata(kAgentToolAccessKey)!);
    expect(kept, {
      'groups': {'start': false},
    });
    expect(
      told.expand((b) => b.changes).whereType<ToolAccessChanged>().single,
      isA<ToolAccessChanged>().having((c) => c.policy, 'policy', kept),
    );
  });

  test('back to the defaults, a subscriber hears nothing again', () {
    final service = DataService(db, clock: () => t0);
    final app = service.open((_) {});
    app.handle(const AgentsToolAccessSet(policy: policy));
    app.handle(const AgentsToolAccessSet(policy: {}));
    expect(greeting(service), isNot(contains(isA<ToolAccessChanged>())));
  });

  test('is not a preference a client can write', () {
    expect(
      () => DataService(
        db,
        clock: () => t0,
      ).open((_) {}).handle(PreferenceSet(kAgentToolAccessKey, '{}')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.reserved,
        ),
      ),
    );
  });

  test('a phone needs what starting a session needs', () {
    const request = AgentsToolAccessSet(policy: policy);
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

  test('the server announces it', () {
    expect(kServerFeatures, contains(AgentsToolAccessSet.feature));
  });
}
