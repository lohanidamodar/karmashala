import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/agents/data/codex_account_dao.dart';
import 'package:karmashala/src/features/agents/data/codex_auth_service.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  String token(Map<String, Object?> claims) {
    final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
    return 'header.${payload.replaceAll('=', '')}.signature';
  }

  test('reads the active identity without a network request', () async {
    final directory = Directory.systemTemp.createTempSync('codex-auth-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final auth = File('${directory.path}${Platform.pathSeparator}auth.json');
    auth.writeAsStringSync(
      jsonEncode({
        'tokens': {
          'account_id': 'account-1',
          'id_token': token({
            'email': 'owner@example.com',
            'exp': 1893456000,
            'https://api.openai.com/auth': {
              'chatgpt_plan_type': 'pro',
            },
          }),
        },
      }),
    );
    final service = CodexAuthService(
      ids: SequentialIdGenerator(),
      clock: const SystemClock(),
    );

    final snapshot = await service.readSnapshot(auth.path, 'windows');

    expect(snapshot.accountId, 'account-1');
    expect(snapshot.email, 'owner@example.com');
    expect(snapshot.planType, 'pro');
    expect(snapshot.accessTokenExpiresAt, DateTime.utc(2030));
  });

  test('capture persists one row per Codex account', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dao = CodexAccountDao(db);
    final directory = Directory.systemTemp.createTempSync('codex-auth-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final auth = File('${directory.path}${Platform.pathSeparator}auth.json');
    auth.writeAsStringSync(
      jsonEncode({
        'tokens': {
          'account_id': 'account-1',
          'id_token': token({'email': 'first@example.com'}),
        },
      }),
    );
    final service = CodexAuthService(
      ids: SequentialIdGenerator(),
      clock: FixedClock(testTime),
    );

    final first = dao.upsert(await service.capture(auth.path, 'windows'));
    auth.writeAsStringSync(
      jsonEncode({
        'tokens': {
          'account_id': 'account-1',
          'id_token': token({'email': 'updated@example.com'}),
        },
      }),
    );
    final updated = dao.upsert(await service.capture(auth.path, 'windows'));

    expect(updated.id, first.id);
    expect(dao.getAll(), hasLength(1));
    expect(dao.getAll().single.email, 'updated@example.com');
  });
}
