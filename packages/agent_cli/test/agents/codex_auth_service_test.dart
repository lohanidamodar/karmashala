import 'dart:io';

import 'package:agent_cli/src/agents/codex/codex_auth_service.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';
import '../support/temp_directory.dart';

void main() {
  late Directory dir;
  late String path;
  final service = CodexAuthService(
    ids: SequentialIdGenerator(),
    clock: FixedClock(DateTime.utc(2026, 1, 1)),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('codex_auth_test');
    path = '${dir.path}${Platform.pathSeparator}auth.json';
  });
  tearDown(() => removeTempDirectory(dir));

  test(
    'an auth.json that is not JSON is named, not read as signed out',
    () async {
      File(path).writeAsStringSync('{"tokens": ');

      final snapshot = await service.readSnapshot(path, 'windows');
      expect(snapshot.isSignedIn, isFalse);
      expect(snapshot.readFailure, contains('is not valid JSON'));

      await expectLater(
        service.capture(path, 'windows'),
        throwsA(
          isA<CodexAuthException>().having(
            (e) => e.message,
            'message',
            contains('is not valid JSON'),
          ),
        ),
      );
    },
  );

  test(
    'an absent auth.json is simply signed out, and capture says it is absent',
    () async {
      final snapshot = await service.readSnapshot(path, 'windows');
      expect(snapshot.isSignedIn, isFalse);
      expect(snapshot.readFailure, isNull);

      await expectLater(
        service.capture(path, 'windows'),
        throwsA(
          isA<CodexAuthException>().having(
            (e) => e.message,
            'message',
            contains('No Codex credentials found'),
          ),
        ),
      );
    },
  );
}
