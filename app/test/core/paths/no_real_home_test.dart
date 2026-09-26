/// Under `flutter test` nothing in the app reaches the owner's real server
/// folder or starts a real `serve` against it: the local host is unreachable
/// unless a test overrides it with folders of its own, the server data folder
/// is refused, and `LocalHostSessionAccess` — the one place a `serve` is
/// spawned — refuses a real start without a data folder and host directory
/// of its own (tested in karmashala_terminal_runtime).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/paths/server_data_directory.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

void main() {
  test('no local host, so no serve and no supervisor, in a test', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(localHostReachableProvider), isFalse);
    expect(container.read(localHostSessionAccessProvider), isNull);
    expect(container.read(localHostSupervisorProvider), isNull);
  });

  test('the server data folder is refused', () async {
    await expectLater(serverDataDirectory(), throwsStateError);
  });

  test('a real serve started bare is refused in a test run', () {
    expect(
      LocalHostSessionAccess.refusalUnderTest(
        arguments: const ['serve'],
        serveEnvironment: null,
        processEnvironment: const {'FLUTTER_TEST': 'true'},
      ),
      isNotNull,
    );
  });
}
