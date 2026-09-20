import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// **A folder that has gone must stop being offered.**
///
/// The owner deleted twenty-one merged `wt-*` worktrees from disk and the Files
/// panel went on listing all twenty-one. [directoryListingProvider] is
/// `autoDispose`, which disposes a listing nobody watches but caches one that
/// stays on screen indefinitely — and the deletion was made from a shell
/// outside the app, so no in-app signal (`CheckoutMoved` and friends) would
/// ever have reported it either.
///
/// The fix is to re-list when the user comes back to the window. These tests
/// pin the two halves of that: a regain re-reads, and a *storm* of regains does
/// not, because every listing on a WSL path crosses 9p and focus is not a rare
/// event.
class _FakeListingService implements FileListingService {
  _FakeListingService(this._entries);

  List<String> _entries;
  var calls = 0;

  set entries(List<String> value) => _entries = value;

  @override
  Future<List<DirEntry>> list(String windowsDir) async {
    calls++;
    return [
      for (final name in _entries)
        DirEntry(
          name: name,
          isDirectory: true,
          windowsPath: '$windowsDir\\$name',
        ),
    ];
  }
}

void main() {
  const dir = r'\\wsl.localhost\archlinux\home\me\hub';
  final t0 = DateTime.utc(2026, 9, 1, 12);

  /// A container whose clock the test drives, so the rate limit is asserted
  /// rather than waited out.
  ({ProviderContainer container, _FakeListingService service, _StepClock clock})
  make(List<String> entries) {
    final service = _FakeListingService(entries);
    final clock = _StepClock(t0);
    final container = ProviderContainer(
      overrides: [
        fileListingServiceProvider.overrideWithValue(service),
        clockProvider.overrideWithValue(clock),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, service: service, clock: clock);
  }

  /// Leaves the window and comes back, which is the gesture under test.
  void altTab(ProviderContainer container) {
    container.read(windowFocusedProvider.notifier).set(false);
    container.read(windowFocusedProvider.notifier).set(true);
  }

  test('a listing is read once while the panel simply sits there', () async {
    final t = make(['wt-adopt', 'wt-attr']);
    await t.container.read(directoryListingProvider(dir).future);
    await t.container.read(directoryListingProvider(dir).future);
    expect(t.service.calls, 1, reason: 'a cached listing was re-read');
  });

  test(
    'coming back to the window stops offering a folder that has gone',
    () async {
      final t = make(['wt-adopt', 'wt-attr', 'lib']);
      final first = await t.container.read(
        directoryListingProvider(dir).future,
      );
      expect(first.map((e) => e.name), ['wt-adopt', 'wt-attr', 'lib']);

      // The worktrees are removed from disk by something outside the app — a
      // shell, another agent — which is exactly the case no in-app signal covers.
      t.service.entries = ['lib'];

      t.clock.advance(kFileListingRefreshInterval);
      altTab(t.container);

      final again = await t.container.read(
        directoryListingProvider(dir).future,
      );
      expect(again.map((e) => e.name), [
        'lib',
      ], reason: 'the panel still offers folders that are gone from disk');
      expect(t.service.calls, 2);
    },
  );

  test('an alt-tab storm costs one listing, not one per tab', () async {
    final t = make(['lib']);
    await t.container.read(directoryListingProvider(dir).future);

    // Ten regains inside the rate-limit window. Each one is a 9p directory
    // listing per expanded folder if it is allowed through.
    t.clock.advance(kFileListingRefreshInterval);
    for (var i = 0; i < 10; i++) {
      altTab(t.container);
      t.clock.advance(const Duration(milliseconds: 100));
    }
    await t.container.read(directoryListingProvider(dir).future);

    expect(
      t.service.calls,
      2,
      reason: 'every focus regain re-listed the directory',
    );
  });

  test('the Refresh button is not rate limited', () async {
    final t = make(['wt-adopt']);
    await t.container.read(directoryListingProvider(dir).future);

    // No clock advance: an explicit click is the user saying they know the
    // tree moved, and making them wait out a window would be absurd.
    t.service.entries = [];
    t.container.read(fileListingRefreshProvider.notifier).refresh();

    final again = await t.container.read(directoryListingProvider(dir).future);
    expect(again, isEmpty);
    expect(t.service.calls, 2);
  });
}

/// A clock the test moves by hand.
class _StepClock implements Clock {
  _StepClock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime nowUtc() => _now;
}
