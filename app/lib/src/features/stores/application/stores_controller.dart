import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:store_console/store_console.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/tab_progress.dart';
import 'store_attention.dart';
import 'store_changes.dart';
import 'store_groups.dart';

/// A view older than this is read again when the tab opens.
const Duration kStoreSnapshotMaxAge = Duration(minutes: 30);

/// What the Stores tab and Settings → Stores draw: the server's view, and how
/// far a refresh under way has got.
class StoresState {
  const StoresState({
    this.view = const StoresView(),
    this.done = 0,
    this.total = 0,
    this.asking = false,
    this.problem,
  });

  final StoresView view;

  /// Apps read so far in the refresh under way, of [total].
  final int done;
  final int total;

  /// A refresh this client asked for has not been answered yet.
  final bool asking;

  /// Why the last refresh asked for did not happen, as a sentence.
  final String? problem;

  Map<StoreKind, Reading<List<StoreApp>>> get stores => view.stores;
  Set<StoreKind> get connected => view.connected;
  DateTime? get refreshedAt => view.refreshedAt;
  bool get refreshing => asking || view.refreshing;

  /// The failures every app of a store shares, said once above the apps.
  List<StoreWideMissing> get storeWide => storeWideMissing(view.apps);

  /// Every app, loudest first. Built afresh on each read: read it once a
  /// build.
  List<StoreAppGroup> get groups => groupStoreView(
    view.stores,
    view.apps,
    icons: view.icons,
    links: view.links,
    storeWide: storeWideByArea(storeWide),
    reads: view.reads,
    changes: {for (final held in view.changes) held.app.key: held},
  );

  StoresState copyWith({
    StoresView? view,
    int? done,
    int? total,
    bool? asking,
    String? Function()? problem,
  }) => StoresState(
    view: view ?? this.view,
    done: done ?? this.done,
    total: total ?? this.total,
    asking: asking ?? this.asking,
    problem: problem == null ? this.problem : problem(),
  );
}

/// A refusal from the server as the sentence shown to the user.
String storeRefusalSentence(DataRefused refusal) => switch (refusal.code) {
  DataRefusalCode.denied =>
    'Store keys are imported in Karmashala on the desktop; this device can '
        'only read them.',
  DataRefusalCode.unavailable =>
    'The Karmashala server did not answer: ${refusal.message}',
  _ => refusal.message,
};

String _unexpected(Object error) =>
    'The Karmashala server could not be asked (${error.runtimeType}).';

String? _optional(String? typed) {
  final value = typed?.trim() ?? '';
  return value.isEmpty ? null : value;
}

/// The app stores as the Karmashala server holds them. The server keeps the
/// credentials, reads the stores and keeps what it read; this client only
/// asks. Read again on open and on request, never on a timer (PROJECT.md §19).
class StoresController extends AsyncNotifier<StoresState> {
  @override
  Future<StoresState> build() async {
    final client = ref.watch(dataClientProvider);
    final changes = client.storesChanges.listen(_told);
    final progress = client.storesProgress.listen((reading) {
      final current = state.value;
      if (current == null || !current.refreshing) return;
      state = AsyncData(
        current.copyWith(done: reading.done, total: reading.total),
      );
    });
    ref.onDispose(changes.cancel);
    ref.onDispose(progress.cancel);
    final told = client.storesView;
    if (told != null) return StoresState(view: told);
    return StoresState(view: (await client.send(const StoresGet())).value);
  }

  void _told(StoresView view) {
    if (!ref.mounted) return;
    final current = state.value ?? const StoresState();
    // Progress belongs to one refresh: it starts again with the next.
    final sameRefresh = view.refreshing && current.view.refreshing;
    state = AsyncData(
      current.copyWith(
        view: view,
        done: sameRefresh ? current.done : 0,
        total: sameRefresh ? current.total : 0,
      ),
    );
  }

  /// Reads the stores again. What the Refresh button calls.
  Future<void> refresh() => _refresh(null);

  /// Reads the stores when the server's view is older than
  /// [kStoreSnapshotMaxAge]. What the tab calls each time it opens.
  Future<void> refreshIfStale() => _refresh(kStoreSnapshotMaxAge.inSeconds);

  Future<void> _refresh(int? maxAgeSeconds) async {
    final StoresState current;
    try {
      current = await future;
    } on Object {
      // The view could not be read; the tab offers to try again.
      return;
    }
    if (!ref.mounted || current.refreshing || current.connected.isEmpty) {
      return;
    }
    // Only a refresh asked for by hand shows at once; a fresh view answers
    // the one on open without a flicker.
    if (maxAgeSeconds == null) {
      state = AsyncData(current.copyWith(asking: true, problem: () => null));
    }
    try {
      final view =
          (await ref
                  .read(dataClientProvider)
                  .send(StoresRefresh(maxAgeSeconds: maxAgeSeconds)))
              .value;
      _told(view);
      _settle(null);
    } on DataRefused catch (refusal) {
      _settle(storeRefusalSentence(refusal));
    } on Object catch (error) {
      // Anything else must still end the spinner, and says only its type.
      _settle(_unexpected(error));
    }
  }

  /// Reads [app] again on its own: the retry on an app whose read failed.
  /// Answers null when the server read it, else a sentence why not.
  Future<String?> retry(StoreApp app) =>
      _write(StoresRefreshApp(store: app.store, id: app.id));

  void _settle(String? problem) {
    if (!ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(asking: false, problem: () => problem));
  }

  /// Imports an App Store Connect key: [pem] is the `.p8`'s text, sent to
  /// the server once. Answers null when kept, else a sentence why not.
  Future<String?> importAppleKey({
    required String pem,
    required String keyId,
    required String issuerId,
    String? vendorNumber,
  }) {
    if (pem.trim().isEmpty) return Future.value('That .p8 file is empty.');
    final key = keyId.trim();
    final issuer = issuerId.trim();
    if (key.isEmpty || issuer.isEmpty) {
      return Future.value('Enter the key ID and the issuer ID.');
    }
    return _write(
      StoreAppleSet(
        keyId: key,
        issuerId: issuer,
        privateKeyPem: pem,
        vendorNumber: _optional(vendorNumber),
      ),
    );
  }

  /// Changes the vendor number of the key the server holds, keeping the key.
  Future<String?> updateApple(String? vendorNumber) async {
    final apple = state.value?.view.apple;
    if (apple == null) return 'No App Store Connect key is imported.';
    return _write(
      StoreAppleSet(
        keyId: apple.keyId,
        issuerId: apple.issuerId,
        vendorNumber: _optional(vendorNumber),
      ),
    );
  }

  /// Imports a Google Play service account: [json] is the key file's text,
  /// sent to the server once.
  Future<String?> importPlayAccount({
    required String json,
    String? bucket,
    List<String> packageNames = const [],
  }) {
    if (json.trim().isEmpty) {
      return Future.value('That service-account file is empty.');
    }
    return _write(
      StorePlaySet(
        serviceAccountJson: json,
        reportsBucket: _optional(bucket),
        packageNames: packageNames,
      ),
    );
  }

  /// Changes the bucket and package names, keeping the account's key.
  Future<String?> updatePlay({
    String? bucket,
    required List<String> packageNames,
  }) async {
    if (state.value?.view.play == null) {
      return 'No Google Play service account is imported.';
    }
    return _write(
      StorePlaySet(
        reportsBucket: _optional(bucket),
        packageNames: packageNames,
      ),
    );
  }

  /// Apps [appKeys] were opened: what changed about them is seen, at the
  /// server and in its inbox. Nothing is asked when nothing is unseen.
  void markSeen(Iterable<String> appKeys) {
    final keys = appKeys.toSet();
    final unseen = ref
        .read(storeChangesProvider)
        .any((held) => !held.seen && keys.contains(held.app.key));
    if (!unseen) return;
    ref.read(storeChangesProvider.notifier).seenHere(keys);
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        current.copyWith(
          view: StoresView(
            apple: current.view.apple,
            play: current.view.play,
            stores: current.view.stores,
            apps: current.view.apps,
            icons: current.view.icons,
            links: current.view.links,
            refreshedAt: current.view.refreshedAt,
            refreshing: current.view.refreshing,
            reads: current.view.reads,
            changes: [
              for (final held in current.view.changes)
                keys.contains(held.app.key) ? held.asSeen() : held,
            ],
            schedule: current.view.schedule,
          ),
        ),
      );
    }
    unawaited(_write(StoresSeen(keys.toList()..sort())));
  }

  /// How often the server reads the stores on its own; [Duration.zero] is
  /// never. Answers null when kept, else a sentence why not.
  Future<String?> setBackgroundEvery(Duration every) =>
      _write(StoresScheduleSet(every));

  /// Forgets [store]'s credential and what was read with it, at the server.
  Future<String?> remove(StoreKind store) =>
      _write(StoreCredentialRemove(store));

  /// Combines [link]'s App Store app and Play app into one, whatever their
  /// ids; either one's earlier pair is undone. Kept by the server, so every
  /// client and the agent tools see it.
  Future<String?> combine(StoreAppLink link) => _write(
    StoreAppsLink(appStoreId: link.appStoreId, packageName: link.packageName),
  );

  /// Separates a pair [combine] made.
  Future<String?> separate(StoreAppLink link) => _write(
    StoreAppsUnlink(appStoreId: link.appStoreId, packageName: link.packageName),
  );

  Future<String?> _write(StoreRequest<StoresView> request) async {
    try {
      _told((await ref.read(dataClientProvider).send(request)).value);
      return null;
    } on DataRefused catch (refusal) {
      return storeRefusalSentence(refusal);
    } on Object catch (error) {
      return _unexpected(error);
    }
  }
}

final storesProvider = AsyncNotifierProvider<StoresController, StoresState>(
  StoresController.new,
);

/// The Stores tab's header: how far a read has got, or how many apps failed
/// their last read; null when there is nothing to say.
final storesTabProgressProvider = Provider<TabProgress?>((ref) {
  final progress = ref.watch(
    storesProvider.select((async) {
      final state = async.value;
      if (state == null) return null;
      final phases = state.view.reads.values.map((read) => read.phase);
      return TabProgress(
        // One app read again on its own is work too.
        running:
            state.refreshing ||
            phases.any((phase) => phase != StoreAppReadPhase.failed),
        done: state.done,
        total: state.total,
        failed: phases
            .where((phase) => phase == StoreAppReadPhase.failed)
            .length,
      );
    }),
  );
  return progress == null || progress.quiet ? null : progress;
});
