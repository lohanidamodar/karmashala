import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../data/dtd_link.dart';
import '../data/flutter_app_link.dart';
import '../data/vm_service_uri_directory.dart';
import '../domain/app_log_record.dart';
import '../domain/attached_app.dart';
import '../domain/dtd_instance.dart';
import '../domain/flutter_app_failure.dart';
import '../domain/flutter_app_registry.dart';
import '../domain/vm_service_uri.dart';
import '../domain/widget_selection.dart';
import 'flutter_app_providers.dart';

/// Every running Flutter app this workspace can reach, and the connections to
/// them.
///
/// **A registry, not a connection.** This workspace splits into groups so
/// several things run side by side, and a Flutter desktop build, an Android
/// build on the mirrored phone and an iOS Simulator build are all normal at
/// once. Each is its own row with its own connection, its own console and its
/// own answer to "can this be hot reloaded"; a surface that acts on one names
/// which one.
///
/// **Three readers, and none of them asks the user for anything.** A run this
/// app started writes a `--vmservice-out-file`; every other `flutter run` on
/// this machine is found through the Dart Tooling Daemon it starts, which
/// records its own address on disk and hands over each attached app's VM
/// service URI, token and all; an app on a device is found by
/// `AndroidAppDiscovery` from the line the VM prints to the log. Only a run on
/// another machine still needs an address pasted.
///
/// **Nothing polls.** Discovery is two directory subscriptions, a daemon event
/// stream and an explicit look; a connection reports its own death through
/// `FlutterAppLink.done`. There is no timer anywhere in this file, and the
/// first look happens when a surface opens or a caller asks — never at
/// start-up, which nothing here is worth adding to.
class AttachedApps extends Notifier<FlutterAppRegistry> {
  AttachedApps({AppLogger? logger})
    : _logger = logger ?? AppLogger.named('flutter_apps');

  final AppLogger _logger;

  final Map<String, FlutterAppLink> _links = <String, FlutterAppLink>{};
  StreamSubscription<FileSystemEvent>? _watch;
  StreamSubscription<FileSystemEvent>? _daemonWatch;
  VmServiceUriDirectory? _directory;
  Future<void>? _looking;

  /// Rows a discovery is opening a connection for right now.
  ///
  /// Two announcements of one app can arrive a microtask apart — a daemon
  /// event and a sweep — and both would pass the "already attached" check
  /// while the first handshake is still in flight. One connection per app.
  final Set<String> _connecting = <String>{};

  /// One open conversation per tooling daemon, keyed by its pid. Held open so
  /// an app that starts later in an IDE's long-lived daemon arrives as an
  /// event — the pid file does not change when it does.
  final Map<int, DtdLink> _daemons = <int, DtdLink>{};

  /// Whether this notifier is still alive.
  ///
  /// A link's teardown finishes *after* the container that owns this notifier
  /// is disposed — closing a connection is asynchronous — so every callback a
  /// link can fire has to be able to find out that there is no longer any
  /// state to write. Riverpod raises on a `Ref` used past disposal, and the
  /// answer is to stop rather than to catch it.
  var _mounted = true;

  @override
  FlutterAppRegistry build() {
    ref.onDispose(() {
      _mounted = false;
      _watch?.cancel();
      _daemonWatch?.cancel();
      final daemons = _daemons.values.toList(growable: false);
      _daemons.clear();
      for (final daemon in daemons) {
        daemon.dispose();
      }
      final links = _links.values.toList(growable: false);
      _links.clear();
      for (final link in links) {
        link.dispose();
      }
    });
    return const FlutterAppRegistry();
  }

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// The link for [id], or `null` when that app is not attached.
  FlutterAppLink? linkFor(String id) => _links[id];

  /// One app's console, oldest first, or an empty list when not attached.
  List<AppLogRecord> consoleOf(String id) =>
      _links[id]?.console ?? const <AppLogRecord>[];

  /// Looks for running apps: reads the discovery directory, attaches to
  /// anything new and re-measures anything that was unreachable.
  ///
  /// Runs when a surface opens and when someone asks. Concurrent calls share
  /// one sweep rather than racing each other into two connections to the same
  /// app.
  Future<void> look() => _looking ??= _look().whenComplete(() {
    _looking = null;
  });

  Future<void> _look() async {
    if (!_mounted) return;
    final VmServiceUriDirectory directory;
    try {
      directory = await ref.read(flutterAppDiscoveryDirectoryProvider.future);
    } on Object catch (error) {
      state = state.copyWith(
        lookedAt: _now,
        discoveryFailure: '$error',
      );
      return;
    }
    if (!_mounted) return;
    _directory = directory;
    state = state.copyWith(
      discoveryDirectory: directory.path,
      clearDiscoveryFailure: true,
    );
    _startWatching(directory);
    _startWatchingDaemons();

    final files = await directory.scan();
    if (!_mounted) return;
    final daemonApps = await _readDaemons();
    if (!_mounted) return;
    final rows = <String, AttachedApp>{
      for (final app in state.apps) app.id: app,
    };

    // Every file becomes a row. A row already attached is left alone: the
    // connection is the reading, and re-opening it would cost the app a
    // handshake for no new information.
    for (final file in files) {
      final id = AttachedApp.idFor(file.uri);
      final existing = rows[id];
      if (existing != null && existing.isAttached) {
        rows[id] = existing.copyWith(sourcePath: file.path);
        continue;
      }
      rows[id] = AttachedApp(
        id: id,
        uri: file.uri,
        discovery: AppDiscovery.uriFile,
        reachability: AppReachability.unchecked,
        observedAt: _now,
        label: file.label,
        sourcePath: file.path,
      );
    }

    // Every app a daemon names becomes a row too. Same rule as a file: one
    // already attached keeps its connection.
    for (final found in daemonApps) {
      final id = AttachedApp.idFor(found.app.uri);
      final existing = rows[id];
      if (existing != null && existing.isAttached) continue;
      rows[id] = _rowForDaemonApp(found);
    }

    // A file-backed row whose file is gone is dropped; a hand-attached row is
    // kept, because the user's intent did not disappear with a file they never
    // wrote.
    final paths = files.map((file) => file.path).toSet();
    rows.removeWhere(
      (id, app) =>
          app.discovery == AppDiscovery.uriFile &&
          !app.isAttached &&
          (app.sourcePath == null || !paths.contains(app.sourcePath)),
    );

    // A daemon row nobody named this time is gone with the run that made it.
    final named = daemonApps
        .map((found) => AttachedApp.idFor(found.app.uri))
        .toSet();
    rows.removeWhere(
      (id, app) =>
          app.discovery == AppDiscovery.toolingDaemon &&
          !app.isAttached &&
          !named.contains(id),
    );

    state = state.copyWith(
      apps: rows.values.toList(growable: false),
      lookedAt: _now,
    );

    for (final app in rows.values) {
      // Skipped when a daemon event is already opening this one: the sweep and
      // the event can name the same app, and it gets one connection.
      if (app.reachability == AppReachability.unchecked &&
          _connecting.add(app.id)) {
        try {
          await _connect(app);
        } finally {
          _connecting.remove(app.id);
        }
      }
      if (!_mounted) return;
    }
    state = state.copyWith(lookedAt: _now);
  }

  void _startWatching(VmServiceUriDirectory directory) {
    if (_watch != null) return;
    _watch = directory.changes().listen(
      (_) {
        // Coalesced by `_looking`: a single `flutter run` writes its file in
        // more than one event and each one asks the same question.
        look();
      },
      onError: (Object error) =>
          _logger.debug('watching ${directory.path} failed: $error'),
      cancelOnError: false,
    );
  }

  /// A daemon starting or stopping is a file appearing or vanishing, so a
  /// `flutter run` in somebody's terminal reaches us as an event.
  void _startWatchingDaemons() {
    if (_daemonWatch != null) return;
    _daemonWatch = ref
        .read(dtdPidFilesProvider)
        .changes()
        .listen(
          (_) => look(),
          onError: (Object error) =>
              _logger.debug('watching tooling daemons failed: $error'),
          cancelOnError: false,
        );
  }

  /// Every app the tooling daemons on this machine currently know about.
  ///
  /// A daemon that cannot be reached is **dropped rather than reported**: its
  /// pid file outlives a crash, so an unreachable one is ordinary and saying
  /// so would put somebody else's dead process in this app's error surface.
  Future<List<_DaemonApp>> _readDaemons() async {
    final DtdChannelOpener open;
    final List<DtdInstance> instances;
    try {
      open = ref.read(dtdChannelOpenerProvider);
      instances = ref.read(dtdPidFilesProvider).scan();
    } on Object catch (error) {
      _logger.debug('reading tooling daemons failed: $error');
      return const <_DaemonApp>[];
    }

    final found = <_DaemonApp>[];
    final live = <int>{};
    for (final instance in instances) {
      live.add(instance.pid);
      var link = _daemons[instance.pid];
      if (link == null) {
        try {
          link = await DtdLink.open(instance.wsUri, open: open);
        } on Object catch (error) {
          _logger.debug('tooling daemon ${instance.pid}: $error');
          continue;
        }
        if (!_mounted) {
          await link.dispose();
          return found;
        }
        _daemons[instance.pid] = link;
        link.registered.listen((app) => _offerFromDaemon(app, instance));
      }
      try {
        for (final app in await link.apps()) {
          found.add((app: app, daemon: instance));
        }
      } on Object catch (error) {
        _logger.debug('tooling daemon ${instance.pid}: $error');
        await _daemons.remove(instance.pid)?.dispose();
      }
    }

    final gone = _daemons.keys.where((pid) => !live.contains(pid)).toList();
    for (final pid in gone) {
      await _daemons.remove(pid)?.dispose();
    }
    return found;
  }

  /// An app announced in a device log, reachable here through [hostUri].
  ///
  /// [serial] is the device it is on, kept as the row's source so the pane can
  /// say *which* phone. Offered once: an address already attached is left
  /// alone rather than handshaken again.
  Future<void> offerFromDevice({
    required Uri hostUri,
    required String serial,
    String? label,
  }) async {
    if (!_mounted) return;
    final uri = normaliseVmServiceUri(hostUri.toString());
    if (uri == null) return;
    final id = AttachedApp.idFor(uri);
    final existing = state.byId(id);
    if (existing != null && existing.isAttached) return;
    if (!_connecting.add(id)) return;
    final row = AttachedApp(
      id: id,
      uri: uri,
      discovery: AppDiscovery.deviceLog,
      reachability: AppReachability.unchecked,
      observedAt: _now,
      label: label ?? serial,
      sourcePath: serial,
    );
    _replace(row);
    state = state.copyWith(lookedAt: _now);
    try {
      await _connect(row);
    } finally {
      _connecting.remove(id);
    }
  }

  /// An app a daemon named after the sweep that found its daemon.
  void _offerFromDaemon(DtdApp app, DtdInstance daemon) {
    if (!_mounted) return;
    final row = _rowForDaemonApp((app: app, daemon: daemon));
    final existing = state.byId(row.id);
    // Offered once. A second announcement of an app already attached would
    // cost the app a handshake and tell us nothing new.
    if (existing != null && existing.isAttached) return;
    if (!_connecting.add(row.id)) return;
    _replace(row);
    state = state.copyWith(lookedAt: _now);
    unawaited(_connect(row).whenComplete(() => _connecting.remove(row.id)));
  }

  AttachedApp _rowForDaemonApp(_DaemonApp found) => AttachedApp(
    id: AttachedApp.idFor(found.app.uri),
    uri: found.app.uri,
    discovery: AppDiscovery.toolingDaemon,
    reachability: AppReachability.unchecked,
    observedAt: _now,
    label: found.app.name ?? _lastSegment(found.daemon.workspaceRoot),
    sourcePath: found.daemon.workspaceRoot.isEmpty
        ? null
        : found.daemon.workspaceRoot,
  );

  static String _lastSegment(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'a Flutter app' : parts.last;
  }

  /// Attaches to an address the user typed or an agent handed over.
  ///
  /// Idempotent: attaching to an app that is already attached returns the row
  /// it already has, so a retry after a lost reply cannot open two
  /// connections.
  Future<AttachedApp> attach(String rawUri) async {
    final uri = normaliseVmServiceUri(rawUri);
    if (uri == null) {
      throw FlutterAppException(
        FlutterAppFailure.badUri,
        describeFlutterAppFailure(FlutterAppFailure.badUri, detail: rawUri),
      );
    }
    final id = AttachedApp.idFor(uri);
    final existing = state.byId(id);
    if (existing != null && existing.isAttached) return existing;

    final row =
        existing?.copyWith(reachability: AppReachability.unchecked) ??
        AttachedApp(
          id: id,
          uri: uri,
          discovery: AppDiscovery.byHand,
          reachability: AppReachability.unchecked,
          observedAt: _now,
          label: '${uri.host}:${uri.port}',
        );
    _replace(row);
    state = state.copyWith(lookedAt: _now);
    final attached = await _connect(row);
    if (attached.reachability != AppReachability.attached) {
      throw FlutterAppException(
        FlutterAppFailure.connectFailed,
        describeFlutterAppFailure(
          FlutterAppFailure.connectFailed,
          detail: attached.detail,
        ),
      );
    }
    return attached;
  }

  Future<AttachedApp> _connect(AttachedApp app) async {
    try {
      // The clock is read once and handed over: the link outlives a `read`,
      // and a closure over `ref` would throw the moment the container that
      // owns this notifier is disposed — which is exactly when a link is
      // still finishing its teardown.
      final clock = ref.read(clockProvider);
      final link = await FlutterAppLink.attach(
        app.uri,
        connect: ref.read(vmServiceConnectorProvider),
        now: clock.nowUtc,
        logger: _logger,
      );
      _links[app.id] = link;
      unawaited(link.done.then((_) => _onLinkClosed(app.id)));
      final support = await link.widgetLocationSupport();
      if (!_mounted) {
        await link.dispose();
        return app;
      }
      final attached = app.copyWith(
        reachability: AppReachability.attached,
        observedAt: _now,
        isolateId: link.isolateId,
        widgetLocations: support,
        reloadMethod: link.reloadMethod,
        restartMethod: link.restartMethod,
        clearDetail: true,
      );
      _replace(attached);
      // A reload service can appear or vanish after we attach — the tool
      // registers on its own connection and can detach — so the row follows
      // the link rather than freezing what was true at the handshake.
      link.servicesChanged.listen((_) => _refreshServices(app.id));
      return attached;
    } on FlutterAppException catch (error) {
      final failed = app.copyWith(
        reachability: AppReachability.unreachable,
        observedAt: _now,
        detail: error.message,
        clearIsolate: true,
        clearServices: true,
      );
      _replace(failed);
      return failed;
    }
  }

  void _refreshServices(String id) {
    if (!_mounted) return;
    final link = _links[id];
    final app = state.byId(id);
    if (link == null || app == null) return;
    if (app.reloadMethod == link.reloadMethod &&
        app.restartMethod == link.restartMethod) {
      return;
    }
    _replace(
      app.copyWith(
        reloadMethod: link.reloadMethod,
        restartMethod: link.restartMethod,
        clearServices: link.reloadMethod == null,
      ),
    );
  }

  void _onLinkClosed(String id) {
    _links.remove(id);
    if (!_mounted) return;
    final app = state.byId(id);
    if (app == null) return;
    _replace(
      app.copyWith(
        reachability: AppReachability.ended,
        observedAt: _now,
        detail: 'The app closed its VM service connection.',
        clearIsolate: true,
        clearServices: true,
      ),
    );
  }

  void _replace(AttachedApp app) {
    if (!_mounted) return;
    final apps = <AttachedApp>[
      for (final existing in state.apps)
        if (existing.id == app.id) app else existing,
    ];
    if (!apps.any((existing) => existing.id == app.id)) apps.add(app);
    state = state.copyWith(apps: apps);
  }

  /// The app a caller meant, refusing rather than guessing when it is not
  /// obvious.
  AttachedApp requireApp(String? id) {
    if (id != null && id.isNotEmpty) {
      final app = state.byId(id);
      if (app == null) {
        throw FlutterAppException(
          FlutterAppFailure.unknownApp,
          describeFlutterAppFailure(
            FlutterAppFailure.unknownApp,
            detail: id,
          ),
        );
      }
      if (!app.isAttached) {
        throw FlutterAppException(
          FlutterAppFailure.connectFailed,
          describeFlutterAppFailure(
            FlutterAppFailure.connectFailed,
            detail: app.detail,
          ),
        );
      }
      return app;
    }
    final only = state.onlyAttached;
    if (only != null) return only;
    if (state.attached.isEmpty) {
      throw FlutterAppException(
        FlutterAppFailure.noAppAttached,
        describeFlutterAppFailure(
          FlutterAppFailure.noAppAttached,
          attachHint: attachHint,
        ),
      );
    }
    throw FlutterAppException(
      FlutterAppFailure.ambiguousApp,
      describeFlutterAppFailure(
        FlutterAppFailure.ambiguousApp,
        detail: state.attached.map((app) => app.id).join(', '),
      ),
    );
  }

  /// The one sentence that says how an app becomes visible.
  ///
  /// §19's "say what to do about it" — and there is now almost nothing to do.
  /// It used to ask the user to add `--vmservice-out-file` pointed at a folder
  /// under *this app's* application-support directory, which was the wrong
  /// thing to ask twice over: it rewrote somebody else's command, and it
  /// pointed it into another program's private folder. The out-file is still
  /// how a run **Karmashala starts** is found, because Karmashala writes that
  /// flag itself; nobody else is asked for it.
  String get attachHint =>
      'A run Karmashala started, a "flutter run" started anywhere else on this '
      'machine, and an app on a connected Android device are all found on '
      'their own. A run on another machine is the one that still needs its '
      'address attached by hand.';

  Future<void> hotReload(String? id) async {
    final app = requireApp(id);
    final link = _links[app.id];
    if (link == null) {
      throw FlutterAppException(
        FlutterAppFailure.disconnected,
        describeFlutterAppFailure(FlutterAppFailure.disconnected),
      );
    }
    await link.hotReload();
  }

  Future<void> hotRestart(String? id) async {
    final app = requireApp(id);
    final link = _links[app.id];
    if (link == null) {
      throw FlutterAppException(
        FlutterAppFailure.disconnected,
        describeFlutterAppFailure(FlutterAppFailure.disconnected),
      );
    }
    await link.hotRestart();
  }

  /// Closes our connection to [id] without touching the app.
  ///
  /// A file-backed row comes back on the next look — which is right: the app
  /// is still running and the file still says so.
  Future<void> detach(String id) async {
    final link = _links.remove(id);
    await link?.dispose();
    final app = state.byId(id);
    if (app == null) return;
    if (app.discovery == AppDiscovery.byHand) {
      state = state.copyWith(
        apps: state.apps.where((existing) => existing.id != id).toList(),
      );
      return;
    }
    _replace(
      app.copyWith(
        reachability: AppReachability.unchecked,
        observedAt: _now,
        clearIsolate: true,
        clearServices: true,
        clearDetail: true,
      ),
    );
  }

  /// Drops a row and, when it came from a file nothing answers on, the file.
  Future<void> forget(String id) async {
    final app = state.byId(id);
    await detach(id);
    final path = app?.sourcePath;
    if (path != null && app != null && !app.isAttached) {
      await _directory?.forget(path);
    }
    state = state.copyWith(
      apps: state.apps.where((existing) => existing.id != id).toList(),
    );
  }

  /// Everything the app has printed, said and thrown, newest last.
  List<AppLogRecord> console(
    String? id, {
    int limit = 200,
    Set<AppLogSource>? sources,
  }) {
    final app = requireApp(id);
    final link = _links[app.id];
    if (link == null) return const <AppLogRecord>[];
    return link.tail(limit: limit, sources: sources);
  }

  /// Turns the running app's widget-select mode on, waits for the user to tap
  /// and reads back what the framework selected.
  ///
  /// The tap does not come through Karmashala at all. On the mirrored device
  /// a touch already reaches the phone through scrcpy's control socket, and on
  /// a desktop build the user clicks the window; the framework hit-tests it,
  /// picks the nearest widget written in the project and pushes a `navigate`
  /// event. So this app does **no** hit-testing, owns no overlay and needs no
  /// coordinate mapping: two service extension calls and a read.
  Future<WidgetSelection> pickWidget(
    String? id, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final app = requireApp(id);
    final link = _links[app.id];
    if (link == null) {
      throw FlutterAppException(
        FlutterAppFailure.disconnected,
        describeFlutterAppFailure(FlutterAppFailure.disconnected),
      );
    }
    if (!link.toolEventStreamListenable) {
      throw FlutterAppException(
        FlutterAppFailure.extensionMissing,
        describeFlutterAppFailure(
          FlutterAppFailure.extensionMissing,
          detail:
              'this VM service does not carry the ToolEvent stream, so the '
              'framework cannot tell us what was selected',
        ),
      );
    }

    final picked = Completer<WidgetSourceLocation>();
    // Subscribed before select mode is armed, so a fast tap cannot land in the
    // gap between the two.
    final subscription = link.navigations.listen((location) {
      if (!picked.isCompleted) picked.complete(location);
    });
    try {
      await link.setWidgetSelectMode(enabled: true);
      final location = await picked.future.timeout(timeout);
      final selection = await link.selectedWidget();
      // The `navigate` event carries the location and no identity, and the
      // read carries the identity and the location. Preferring the read means
      // one description; falling back to the event means a pick still
      // succeeds when the read did not.
      return selection ??
          WidgetSelection(
            description: 'the widget at ${location.asEditorTarget}',
            location: location,
          );
    } on TimeoutException {
      throw FlutterAppException(
        FlutterAppFailure.pickCancelled,
        describeFlutterAppFailure(FlutterAppFailure.pickCancelled),
      );
    } finally {
      await subscription.cancel();
      try {
        await link.setWidgetSelectMode(enabled: false);
      } on FlutterAppException catch (error) {
        _logger.debug('leaving select mode: ${error.message}');
      }
    }
  }
}

final attachedAppsProvider =
    NotifierProvider<AttachedApps, FlutterAppRegistry>(AttachedApps.new);

/// One app, and the daemon that named it — the pair a row is built from.
typedef _DaemonApp = ({DtdApp app, DtdInstance daemon});
