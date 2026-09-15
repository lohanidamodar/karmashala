import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/checkout_default.dart';

import '../../support/fixtures.dart';

/// Which checkout the `+` on a project row starts a session in.
void main() {
  final app = repository(id: 'r1', name: 'app');
  final api = repository(id: 'r2', name: 'api');
  final worktree = repository(id: 'r3', name: 'app-feature');

  test('with nothing chosen it is the first row the picker offers', () {
    expect(
      projectDefaultCheckout(
        defaultRepositoryId: null,
        offered: [app, api],
        all: [app, api, worktree],
      )?.id,
      'r1',
    );
  });

  test('a chosen checkout wins over the picker order', () {
    expect(
      projectDefaultCheckout(
        defaultRepositoryId: 'r2',
        offered: [app, api],
        all: [app, api],
      )?.id,
      'r2',
    );
  });

  test('a choice the picker does not offer is still honoured', () {
    // A worktree is level two of the picker, but a project may well default to
    // one — refusing it would make the setting silently do nothing.
    expect(
      projectDefaultCheckout(
        defaultRepositoryId: 'r3',
        offered: [app, api],
        all: [app, api, worktree],
      )?.id,
      'r3',
    );
  });

  test('a choice that no longer exists falls back rather than refusing', () {
    expect(
      projectDefaultCheckout(
        defaultRepositoryId: 'retired',
        offered: [app, api],
        all: [app, api],
      )?.id,
      'r1',
      reason: 'a retired row must not take the + button down with it',
    );
  });

  test('a project with no checkouts at all answers null', () {
    expect(
      projectDefaultCheckout(
        defaultRepositoryId: 'r1',
        offered: const [],
        all: const [],
      ),
      isNull,
    );
  });

  test('nothing offered still finds a row the workspace knows', () {
    expect(
      projectDefaultCheckout(
        defaultRepositoryId: null,
        offered: const [],
        all: [worktree],
      )?.id,
      'r3',
    );
  });
}
