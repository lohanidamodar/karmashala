part of 'fake_data_server.dart';

/// The server's app stores, in memory: a test seeds [view] and [nextRead]
/// (what a refresh reads), and a client only ever hears summaries. Nothing
/// reaches a store.
class FakeStores {
  FakeStores._(this._server);

  final FakeDataServer _server;

  /// What the server holds now.
  StoresView view = const StoresView();

  /// What the next refresh leaves the view as; null keeps the apps it has.
  StoresView? nextRead;

  /// Refuses the three credential writes, as the server does to a phone.
  bool refuseWrites = false;

  /// The refreshes asked for, by their `maxAgeSeconds`.
  final refreshes = <int?>[];

  /// The key texts the server was handed, so a test can see one arrived.
  final receivedKeys = <String>[];

  /// The view changes at the server, as an agent's refresh would change it.
  void tell(StoresView next) => _changed(next);

  /// A refresh under way has read [done] apps of [total].
  void tellProgress(int done, int total) =>
      _server._tell(null, [StoresProgress(done: done, total: total)]);

  void _changed(StoresView next) {
    view = next;
    // Told to every link, the asker's too, as the server announces it.
    _server._tell(null, [StoresChanged(next)]);
  }

  StoresView _with({
    AppleKeySummary? Function()? apple,
    PlayAccountSummary? Function()? play,
    Map<StoreKind, Reading<List<StoreApp>>>? stores,
    List<StoreAppSnapshot>? apps,
  }) => StoresView(
    apple: apple == null ? view.apple : apple(),
    play: play == null ? view.play : play(),
    stores: stores ?? view.stores,
    apps: apps ?? view.apps,
    refreshedAt: view.refreshedAt,
    refreshing: view.refreshing,
  );

  StoresView _handle(StoreRequest<Object?> request) {
    switch (request) {
      case StoresGet():
        return view;
      case StoresRefresh(:final maxAgeSeconds):
        refreshes.add(maxAgeSeconds);
        final at = view.refreshedAt;
        final fresh =
            maxAgeSeconds != null &&
            at != null &&
            _server._now().difference(at).inSeconds <= maxAgeSeconds;
        if (fresh) return view;
        final read = nextRead;
        final apps = read?.apps ?? view.apps;
        _server._tell(null, [
          StoresProgress(done: apps.length, total: apps.length),
        ]);
        _changed(
          StoresView(
            apple: view.apple,
            play: view.play,
            stores: read?.stores ?? view.stores,
            apps: apps,
            refreshedAt: _server._now(),
          ),
        );
        return view;
      case StoreAppleSet(
        :final keyId,
        :final issuerId,
        :final privateKeyPem,
        :final vendorNumber,
      ):
        _refuseWrite();
        if (privateKeyPem == null && view.apple == null) {
          throw const DataRefused.invalid('No App Store Connect key is held.');
        }
        if (privateKeyPem != null) receivedKeys.add(privateKeyPem);
        _changed(
          _with(
            apple: () => AppleKeySummary(
              keyId: keyId,
              issuerId: issuerId,
              vendorNumber: vendorNumber,
              importedAt: privateKeyPem == null
                  ? view.apple!.importedAt
                  : _server._now(),
            ),
          ),
        );
        return view;
      case StorePlaySet(
        :final serviceAccountJson,
        :final reportsBucket,
        :final packageNames,
      ):
        _refuseWrite();
        final held = view.play;
        if (serviceAccountJson == null && held == null) {
          throw const DataRefused.invalid(
            'No Google Play service account is held.',
          );
        }
        if (serviceAccountJson != null) receivedKeys.add(serviceAccountJson);
        _changed(
          _with(
            play: () => PlayAccountSummary(
              clientEmail: held?.clientEmail ?? 'reader@example.iam',
              reportsBucket: reportsBucket,
              packageNames: packageNames,
              importedAt: serviceAccountJson == null
                  ? held!.importedAt
                  : _server._now(),
            ),
          ),
        );
        return view;
      case StoreCredentialRemove(:final store):
        _refuseWrite();
        _changed(
          _with(
            apple: store == StoreKind.appStore ? () => null : null,
            play: store == StoreKind.googlePlay ? () => null : null,
            stores: {...view.stores}..remove(store),
            apps: [
              for (final app in view.apps)
                if (app.app.store != store) app,
            ],
          ),
        );
        return view;
      default:
        // The protocol's private base class hides the list from the analyzer.
        throw StateError('this fake does not answer ${request.kind}');
    }
  }

  void _refuseWrite() {
    if (refuseWrites) {
      throw const DataRefused.denied(
        'Store keys are set from a desktop, not a phone.',
      );
    }
  }
}
