import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/remote.dart'
    show kPopupBitsRelayUrl, kRetiredPopupBitsRelayUrls;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A server.json that still names a retired PopupBits relay — written when
/// that was the default — is rewritten to the current one when it is read:
/// once, and said in the log. Any other relay is never touched.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ks-retired-relay-'));
  tearDown(() => dir.deleteSync(recursive: true));

  File file() => File(p.join(dir.path, 'server.json'));

  void writeConfig(Map<String, Object?> companion) => file().writeAsStringSync(
    jsonEncode({'name': 'desk', 'companion': companion}),
  );

  Map<String, Object?> companionOnDisk() =>
      (jsonDecode(file().readAsStringSync()) as Map)['companion']
          as Map<String, Object?>;

  test('the retired relay is rewritten to the current one, once, '
      'logged', () async {
    writeConfig({
      'enabled': true,
      'relay': kRetiredPopupBitsRelayUrls.first,
      'relayEnabled': true,
    });
    final said = <String>[];

    final config = await ServerConfig.read(dir.path, log: said.add);

    expect(config.relay, Uri.parse(kPopupBitsRelayUrl));
    expect(companionOnDisk()['relay'], kPopupBitsRelayUrl);
    expect(companionOnDisk()['enabled'], isTrue, reason: 'nothing else moves');
    expect(said.single, contains('relay.popupbits.com'));
    expect(said.single, contains('kmrelay.popupbits.com'));

    said.clear();
    await ServerConfig.read(dir.path, log: said.add);
    expect(said, isEmpty, reason: 'once');
  });

  test('a self-hosted relay, and an empty one, are never touched', () async {
    writeConfig({'relay': 'wss://relay.my-own.net'});
    final before = file().readAsStringSync();
    final said = <String>[];
    final config = await ServerConfig.read(dir.path, log: said.add);
    expect(config.relay, Uri.parse('wss://relay.my-own.net'));
    expect(file().readAsStringSync(), before);
    expect(said, isEmpty);

    writeConfig({'enabled': true});
    final empty = file().readAsStringSync();
    expect((await ServerConfig.read(dir.path)).relay, isNull);
    expect(file().readAsStringSync(), empty);
  });
}
