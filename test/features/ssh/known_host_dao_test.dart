import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

KnownHostKey key({
  String host = 'build-box',
  int port = 22,
  String type = 'ssh-ed25519',
  String fingerprint = 'SHA256:abc',
}) => KnownHostKey(
  host: host,
  port: port,
  keyType: type,
  fingerprint: fingerprint,
  trustedAt: testTime,
);

void main() {
  late AppDatabase db;
  late KnownHostDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = KnownHostDao(db);
  });
  tearDown(() => db.close());

  test('trust then find', () {
    dao.trust(key());
    expect(dao.find('build-box', 22), key());
    expect(dao.find('build-box', 2222), isNull);
    expect(dao.find('other', 22), isNull);
  });

  test('one key per address, so a second trust replaces the first', () {
    dao.trust(key());
    dao.trust(key(fingerprint: 'SHA256:xyz'));
    expect(dao.getAll(), hasLength(1));
    expect(dao.find('build-box', 22)!.fingerprint, 'SHA256:xyz');
  });

  test('forget removes only that address', () {
    dao.trust(key());
    dao.trust(key(port: 2222));
    dao.forget('build-box', 22);
    expect(dao.find('build-box', 22), isNull);
    expect(dao.find('build-box', 2222), isNotNull);
  });
}
