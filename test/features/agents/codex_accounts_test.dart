import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/discovery.dart' show SystemClock;
import 'package:karmashala/src/features/agents/data/codex_account_dao.dart';
import 'package:agent_cli/usage.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

void main() {
  String token(Map<String, Object?> claims) {
    final payload = base64Url.encode(utf8.encode(jsonEncode(claims)));
    return 'header.${payload.replaceAll('=', '')}.signature';
  }

  test('reads the active identity without a network request', () async {
    final directory = Directory.systemTemp.createTempSync('codex-auth-');
    addTearDown(() => removeTempDirectory(directory));
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
    addTearDown(() => removeTempDirectory(directory));
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

  test('switch replaces only tokens, atomically, with one backup', () async {
    final directory = Directory.systemTemp.createTempSync('codex-switch-');
    addTearDown(() => removeTempDirectory(directory));
    final auth = File('${directory.path}${Platform.pathSeparator}auth.json');
    final original = {
      'OPENAI_API_KEY': 'keep-me',
      'last_refresh': 'keep-this-too',
      'tokens': {'account_id': 'outgoing'},
    };
    auth.writeAsStringSync(jsonEncode(original));
    final service = CodexAuthService(
      ids: SequentialIdGenerator(),
      clock: FixedClock(testTime),
    );
    final saved = CodexAccount(
      id: 'saved',
      accountId: 'incoming',
      auth: const {
        'tokens': {'account_id': 'incoming', 'refresh_token': 'secret'},
      },
      capturedAt: testTime,
    );

    await service.switchTo(saved, auth.path);

    final switched = jsonDecode(auth.readAsStringSync()) as Map<String, dynamic>;
    expect(switched['OPENAI_API_KEY'], 'keep-me');
    expect(switched['last_refresh'], 'keep-this-too');
    expect((switched['tokens'] as Map)['account_id'], 'incoming');
    expect(File('${auth.path}.karmashala.tmp').existsSync(), isFalse);
    expect(
      jsonDecode(File('${auth.path}.karmashala.bak').readAsStringSync()),
      original,
    );

    // A later switch must not replace the known-good recovery copy.
    await service.switchTo(saved, auth.path);
    expect(
      jsonDecode(File('${auth.path}.karmashala.bak').readAsStringSync()),
      original,
    );
  });

  test('switch refuses malformed live auth without touching it', () async {
    final directory = Directory.systemTemp.createTempSync('codex-switch-');
    addTearDown(() => removeTempDirectory(directory));
    final auth = File('${directory.path}${Platform.pathSeparator}auth.json')
      ..writeAsStringSync('{broken');
    final service = CodexAuthService(
      ids: SequentialIdGenerator(),
      clock: FixedClock(testTime),
    );
    final saved = CodexAccount(
      id: 'saved',
      accountId: 'incoming',
      auth: const {
        'tokens': {'account_id': 'incoming'},
      },
      capturedAt: testTime,
    );

    await expectLater(
      service.switchTo(saved, auth.path),
      throwsA(isA<CodexAuthException>()),
    );
    expect(auth.readAsStringSync(), '{broken');
    expect(File('${auth.path}.karmashala.bak').existsSync(), isFalse);
    expect(File('${auth.path}.karmashala.tmp').existsSync(), isFalse);
  });
}
