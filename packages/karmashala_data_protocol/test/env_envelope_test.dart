import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The server's environment vault (slice 5a): write-only. A value goes
/// client → server in `env.set` and nowhere else — no answer, no change, no
/// `toString` carries one.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 8);

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const EnvList(),
      const EnvSet('API_TOKEN', 's3cret-value'),
      const EnvRemove('API_TOKEN'),
      const EnvRename('API_TOKEN', 'TOKEN'),
      const EnvRename('API_TOKEN', 'TOKEN', value: 's3cret-value'),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<EnvVaultRequest<Object?>>());
      expect(
        jsonEncode(read.request!.argumentsToJson()),
        jsonEncode(request.argumentsToJson()),
        reason: request.kind,
      );
    }
    final set =
        DataEnvelope.readRequest(
              overTheWire(
                DataEnvelope.request(3, const EnvSet('A', 'the value')),
              ),
            ).request!
            as EnvSet;
    expect(set.variable, 'A');
    expect(set.value, 'the value');
  });

  test('a request prints its kind, never the value it carries', () {
    const set = EnvSet('API_TOKEN', 's3cret-value');
    expect('$set', isNot(contains('s3cret-value')));
    expect('$set', contains('env.set'));
  });

  test('a listing carries names and times, and no value field at all', () {
    final names = [EnvVariableName(name: 'API_TOKEN', updatedAt: t0)];
    final json = DataEnvelope.answer(4, const EnvList(), DataReply(names, 9));
    final text = jsonEncode(json);
    expect(text, isNot(contains('value')));
    final reply = DataEnvelope.readAnswer(overTheWire(json), const EnvList());
    expect(reply.value, names);
  });

  test('the names are told as a change, whole', () {
    final batch = DataChanges(5, [
      EnvVariablesChanged([
        EnvVariableName(name: 'A', updatedAt: t0),
        EnvVariableName(name: 'B', updatedAt: t0),
      ]),
    ]);
    final back = DataEnvelope.readChanges(
      overTheWire(DataEnvelope.changes(batch)),
    );
    final change = back.changes.single as EnvVariablesChanged;
    expect([for (final v in change.variables) v.name], ['A', 'B']);
  });

  test('names and values are refused by the vault rules', () {
    expect(envNameRefusal('GOOD_NAME'), isNull);
    expect(envNameRefusal(''), isNotNull);
    expect(envNameRefusal('1BAD'), isNotNull);
    expect(envNameRefusal('KARMASHALA_SESSION_ID'), isNotNull);
    expect(envNameRefusal('path'), isNotNull);
    expect(envValueRefusal('fine'), isNull);
    expect(envValueRefusal('a\u0000b'), isNotNull);
    expect(envValueRefusal('x' * (kMaxEnvValueLength + 1)), isNotNull);
  });
}
