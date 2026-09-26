/// "The cached stat, never a git of our own."
///
/// `ref.read` on an `autoDispose` provider that nothing is holding **creates
/// it and runs its body**, then answers `AsyncLoading` and lets it go again.
/// So a lookup written as "read it if somebody already measured it" started a
/// `git status` per checkout, threw the answer away as not-measured-yet, and
/// did it again on the next call — which, on the remote path, is once per
/// session on every sweep of the session list.
library;

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:riverpod/riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the branch lookup starts no measurement of its own', () async {
    var measurements = 0;
    final container = ProviderContainer(
      overrides: [
        checkoutStatProvider.overrideWith((ref, checkout) async {
          measurements++;
          return const SessionDiffStat(branch: 'main');
        }),
      ],
    );
    addTearDown(container.dispose);

    const path = EnvironmentPath(
      environmentId: 'local',
      path: r'C:\work\karmashala',
    );
    final branchOf = container.read(remoteCheckoutBranchProvider);

    for (var i = 0; i < 3; i++) {
      expect(branchOf(path), isNull, reason: 'nothing has measured it');
      // Long enough for an autoDispose provider nobody holds to be let go, so
      // the next call would create it again.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    expect(
      measurements,
      0,
      reason:
          'the lookup ran $measurements git measurements it then ignored — '
          'one per call, and the remote session list calls it per session',
    );
  });

  test('a measurement somebody else is holding is still read', () async {
    final container = ProviderContainer(
      overrides: [
        checkoutStatProvider.overrideWith(
          (ref, checkout) async => const SessionDiffStat(branch: 'main'),
        ),
      ],
    );
    addTearDown(container.dispose);

    const path = EnvironmentPath(
      environmentId: 'local',
      path: r'C:\work\karmashala',
    );
    // What the Explorer does while a row is on screen.
    final held = container.listen(
      checkoutStatProvider(const Checkout(path)),
      (_, _) {},
    );
    addTearDown(held.close);
    await container.read(checkoutStatProvider(const Checkout(path)).future);

    expect(container.read(remoteCheckoutBranchProvider)(path), 'main');
  });
}
