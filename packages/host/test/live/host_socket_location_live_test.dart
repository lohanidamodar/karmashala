@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_local_ipc/socket_location.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// A real `serve` in a home too deep for its socket still serves, from a short
/// private directory, and a client that computes the path itself finds it there.
///
/// The host's socket is `$HOME/.karmashala/host.sock`. A long or non-Latin home
/// pushes that past what the system binds — 103 bytes on macOS, measured — and
/// `serve` used to die on the OS's "the length of path exceeds the limit".
void main() {
  test('a home too deep for the socket still serves, from a short private directory', () async {
    final home = Directory(
      '${temporaryHome('ksl').path}/${'h' * 60}/${'o' * 30}',
    )..createSync(recursive: true);
    final preferred = '${home.path}/.karmashala/host.sock';
    expect(
      utf8.encode(preferred).length,
      greaterThan(maxSocketPathBytes(Platform.operatingSystem)),
      reason: 'the case this is about: the host\'s own directory cannot hold it',
    );

    final host = await LocalHost.start(home);
    addTearDown(host.kill);

    expect(host.greeting, contains('socket moved'));
    // Computed in *this* process, by the same rule the daemon used: the banner
    // naming this exact path is the two of them agreeing.
    expect(host.socketPath, isNot(preferred));
    expect(host.greeting, contains(host.socketPath));

    final client = await LocalHostClient.connect(host.socketPath, 'socket-location');
    addTearDown(client.close);
    client.send(ListMessage(client.nextId()));
    final listed = await client.expect<SessionsMessage>();
    expect(listed.summaries, isEmpty);
  }, testOn: 'mac-os || linux');
}
