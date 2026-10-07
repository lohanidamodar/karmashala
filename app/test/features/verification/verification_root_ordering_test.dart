import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala/src/features/verification/domain/session_verdict.dart';
import 'package:karmashala/src/features/verification/presentation/session_verdict_mark.dart';

import '../../support/fake_data_server.dart';

/// **Asking what a session's verdict is must not reach the filesystem.**
///
/// `verificationRootProvider` is resolved from disk, so it cannot answer until
/// something has awaited `resolveVerificationRoot()`; until then it throws. And
/// a Riverpod `Provider` that threw is cached in its error state **for the life
/// of the process** — resolving the root afterwards does not revive it. So one
/// early read of anything that reaches the root permanently breaks every plain
/// provider above it.
///
/// That is not a hypothetical. Measured on the owner's running 1.7.0+18:
/// `_DeliveryStripState.build` watched `sessionVerdictProvider` on the **warm-up
/// frame**, before anything had resolved the root. The strip itself survived —
/// the revision stream turns a build failure into `AsyncValue.error`, which is
/// swallowed — but `verificationRootProvider`, `verificationArtifactStoreProvider`
/// and `verificationServiceProvider` were left errored underneath it. From then
/// on the verification pane's own `ref.watch(verificationRunsProvider)` threw
/// `ProviderException: Tried to use a provider that is in error state`, and
/// `verification_list` over MCP threw the same thing **even though it awaits
/// `resolveVerificationRoot()` first**, which is what proved the state was
/// cached rather than merely early.
///
/// In a release build a widget that throws while building is replaced by
/// Flutter's default `ErrorWidget`: `Color(0xF0C0C0C0)`, near-white, with its
/// message behind an `assert`. Against the dark theme that is the blank white
/// panel the owner reported. There is no colour bug in this feature — the white
/// *is* the crash.
void main() {
  late DataClient client;

  setUp(() async => client = await FakeDataServer().connect());

  /// The app's own first frame: the server's data, and an artifact root that is not
  /// resolved yet. [root] stands in for the global `resolveVerificationRoot()`
  /// fills in later — the ordering under test is which provider is *read*
  /// first, not how the directory is found.
  (ProviderContainer, void Function(Directory)) launching() {
    Directory? resolved;
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        verificationRootProvider.overrideWith((ref) {
          final root = resolved;
          if (root == null) {
            throw StateError('the artifact root is not resolved yet');
          }
          return root;
        }),
      ],
    );
    addTearDown(container.dispose);
    return (container, (root) => resolved = root);
  }

  test('a session verdict is answered before the root is resolved', () {
    final (container, _) = launching();
    expect(
      container.read(sessionVerdictProvider('s-1')).state,
      SessionVerdictState.notRecorded,
    );
  });

  test(
    'and the strip asking first does not break the pane afterwards',
    () async {
      final (container, resolve) = launching();
      final root = Directory.systemTemp.createTempSync('verify-root-order');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      // The warm-up frame: every session view hosts a delivery strip, and it is
      // drawn long before anything has opened the verification pane.
      container.read(sessionVerdictProvider('s-1'));

      // The pane opens, and `verificationRootReadyProvider` resolves the root.
      resolve(root);

      // The list the pane draws. This is the read that used to throw
      // `ProviderException` and paint a white rectangle.
      expect(await container.read(verificationRunsProvider.future), isEmpty);
      expect(container.read(verificationServiceProvider), isNotNull);
    },
  );

  testWidgets('the mark draws on a launch that has resolved nothing', (
    tester,
  ) async {
    final (container, _) = launching();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: SessionVerdictMark(sessionId: 's-1')),
        ),
      ),
    );
    await tester.pump();

    // What matters is building without a throw while nothing has resolved.
    // Nothing checked now draws nothing on the bar (owner, 2026-10-07).
    expect(tester.takeException(), isNull);
    expect(find.byType(SessionVerdictMark), findsOneWidget);
    expect(find.text(SessionVerdictState.notRecorded.label), findsNothing);
  });
}
