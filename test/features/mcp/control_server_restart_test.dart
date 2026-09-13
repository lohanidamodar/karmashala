import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/mcp/control_server_restart.dart';

/// **Restarting the server this app owns.**
///
/// The one thing it must not do is claim to restart the bridge inside an agent
/// session: that process is the CLI's own child, bound when the session
/// started (§19). What it can do is rebind this app's endpoint — and the rule
/// that matters is that the hook token is rewritten with it, because `start()`
/// mints a fresh one and every agent's config still holds the old.
void main() {
  test('a run that started no server says so rather than pretending', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await restartControlServer(container);

    expect(result.ok, isFalse);
    expect(result.message, contains('never started a control server'));
    expect(
      container.read(controlServerRestartingProvider),
      isFalse,
      reason: 'a refusal must not leave the button disabled for ever',
    );
  });

  test('nothing is in flight before anything is pressed', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(controlServerRestartingProvider), isFalse);
    expect(container.read(controlServerHandleProvider), isNull);
  });

  test('a second press while one is running is refused by name', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(controlServerRestartingProvider.notifier).set(true);

    final result = await restartControlServer(container);

    // Asked *before* the handle, or this would answer "never started" and the
    // guard would never be reached at all.
    expect(result.message, 'A restart is already running.');
    expect(
      container.read(controlServerRestartingProvider),
      isTrue,
      reason: 'the in-flight restart owns the flag; a refusal never clears it',
    );
  });
}
