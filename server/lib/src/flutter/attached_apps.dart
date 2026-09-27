import 'dart:async';
import 'dart:io';

import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// Every running Flutter app the server can reach: found through its own
/// runs' out-files, the tooling daemons on its machine, a phone on its
/// machine whose log announced one (`DeviceAppDiscovery`, forwarded by the
/// server's own adb), or an address handed to it. Nothing polls; [onChanged]
/// hears every change of [registry].
class ServerAttachedApps {
  ServerAttachedApps({
    required this.directory,
    required this.dtdPidFiles,
    this.openDtd = openDtdOverWebSocket,
    this.connect = connectVmServiceOverWebSocket,
    DateTime Function()? clock,
    this.onChanged,
    void Function(String message)? log,
  }) : _now = clock ?? _utcNow,
       _log = log ?? _silent;

  /// Where the runs this server starts write their `--vmservice-out-file`.
  final VmServiceUriDirectory directory;
  final DtdPidFiles dtdPidFiles;
  final DtdChannelOpener openDtd;
  final VmServiceConnector connect;
  final void Function(FlutterAppRegistry registry)? onChanged;
  final DateTime Function() _now;
  final void Function(String message) _log;
  static void _silent(String _) {}

  static DateTime _utcNow() => DateTime.now().toUtc();

  FlutterAppRegistry _registry = const FlutterAppRegistry();
  FlutterAppRegistry get registry => _registry;
  set _state(FlutterAppRegistry next) {
    _registry = next;
    if (_open) onChanged?.call(next);
  }

  final _links = <String, FlutterAppLink>{};
  final _daemons = <int, DtdLink>{};

  /// Apps a discovery is opening a connection for right now, one each.
  final _connecting = <String>{};
  StreamSubscription<FileSystemEvent>? _watch;
  StreamSubscription<void>? _daemonWatch;
  Future<void>? _looking;
  var _open = true;

  FlutterAppLink? linkFor(String id) => _links[id];

  /// Told whenever somebody looks for apps — the device-log discovery
  /// (`DeviceAppDiscovery`) reads the phones while they are being looked at.
  void Function()? onLooked;

  /// Looks for running apps: attaches to anything new, re-measures anything
  /// unreachable. Concurrent calls share one sweep.
  Future<void> look() {
    onLooked?.call();
    return _looking ??= _look().whenComplete(() => _looking = null);
  }

  Future<void> _look() async {
    if (!_open) return;
    try {
      await directory.ensureExists();
    } on Object catch (error) {
      _state = _registry.copyWith(lookedAt: _now(), discoveryFailure: '$error');
      return;
    }
    _state = _registry.copyWith(
      discoveryDirectory: directory.path,
      clearDiscoveryFailure: true,
    );
    _startWatching();

    final files = await directory.scan();
    if (!_open) return;
    final daemonApps = await _readDaemons();
    if (!_open) return;
    final rows = <String, AttachedApp>{
      for (final app in _registry.apps) app.id: app,
    };
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
        observedAt: _now(),
        label: file.label,
        sourcePath: file.path,
      );
    }
    for (final found in daemonApps) {
      final id = AttachedApp.idFor(found.app.uri);
      final existing = rows[id];
      if (existing != null && existing.isAttached) continue;
      rows[id] = _rowForDaemonApp(found);
    }
    // A hand-attached row survives; a file row whose file went goes.
    final paths = files.map((file) => file.path).toSet();
    rows.removeWhere(
      (id, app) =>
          app.discovery == AppDiscovery.uriFile &&
          !app.isAttached &&
          (app.sourcePath == null || !paths.contains(app.sourcePath)),
    );
    final named = daemonApps.map((f) => AttachedApp.idFor(f.app.uri)).toSet();
    rows.removeWhere(
      (id, app) =>
          app.discovery == AppDiscovery.toolingDaemon &&
          !app.isAttached &&
          !named.contains(id),
    );
    _state = _registry.copyWith(
      apps: rows.values.toList(growable: false),
      lookedAt: _now(),
    );
    for (final app in rows.values) {
      if (app.reachability == AppReachability.unchecked &&
          _connecting.add(app.id)) {
        try {
          await _connect(app);
        } finally {
          _connecting.remove(app.id);
        }
      }
      if (!_open) return;
    }
    _state = _registry.copyWith(lookedAt: _now());
  }

  void _startWatching() {
    _watch ??= directory.changes().listen(
      (_) => look(),
      onError: (Object error) =>
          _log('watching ${directory.path} failed: $error'),
      cancelOnError: false,
    );
    _daemonWatch ??= dtdPidFiles.changes().listen(
      (_) => look(),
      onError: (Object error) =>
          _log('watching tooling daemons failed: $error'),
      cancelOnError: false,
    );
  }

  /// Every app the tooling daemons here know. An unreachable daemon is
  /// dropped: its pid file outlives a crash.
  Future<List<_DaemonApp>> _readDaemons() async {
    final List<DtdInstance> instances;
    try {
      instances = dtdPidFiles.scan();
    } on Object catch (error) {
      _log('reading tooling daemons failed: $error');
      return const [];
    }
    final found = <_DaemonApp>[];
    final live = <int>{};
    for (final instance in instances) {
      live.add(instance.pid);
      var link = _daemons[instance.pid];
      if (link == null) {
        try {
          link = await DtdLink.open(instance.wsUri, open: openDtd);
        } on Object catch (error) {
          _log('tooling daemon ${instance.pid}: $error');
          continue;
        }
        if (!_open) {
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
        _log('tooling daemon ${instance.pid}: $error');
        await _daemons.remove(instance.pid)?.dispose();
      }
    }
    for (final pid in _daemons.keys.where((p) => !live.contains(p)).toList()) {
      await _daemons.remove(pid)?.dispose();
    }
    return found;
  }

  void _offerFromDaemon(DtdApp app, DtdInstance daemon) {
    if (!_open) return;
    final row = _rowForDaemonApp((app: app, daemon: daemon));
    final existing = _registry.byId(row.id);
    if (existing != null && existing.isAttached) return;
    if (!_connecting.add(row.id)) return;
    _replace(row);
    _state = _registry.copyWith(lookedAt: _now());
    unawaited(_connect(row).whenComplete(() => _connecting.remove(row.id)));
  }

  AttachedApp _rowForDaemonApp(_DaemonApp found) => AttachedApp(
    id: AttachedApp.idFor(found.app.uri),
    uri: found.app.uri,
    discovery: AppDiscovery.toolingDaemon,
    reachability: AppReachability.unchecked,
    observedAt: _now(),
    label: found.app.name ?? _lastSegment(found.daemon.workspaceRoot),
    sourcePath: found.daemon.workspaceRoot.isEmpty
        ? null
        : found.daemon.workspaceRoot,
  );

  static String _lastSegment(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'a Flutter app' : parts.last;
  }

  /// Attaches to an address a person or an agent handed over — or, with
  /// [deviceSerial], one a device's log announced. Idempotent. Throws
  /// [FlutterAppException] when nothing answers.
  Future<AttachedApp> attach(
    String rawUri, {
    String? deviceSerial,
    String? label,
  }) async {
    final uri = normaliseVmServiceUri(rawUri);
    if (uri == null) {
      throw FlutterAppException(
        FlutterAppFailure.badUri,
        describeFlutterAppFailure(FlutterAppFailure.badUri, detail: rawUri),
      );
    }
    final id = AttachedApp.idFor(uri);
    final existing = _registry.byId(id);
    if (existing != null && existing.isAttached) return existing;
    final row =
        existing?.copyWith(reachability: AppReachability.unchecked) ??
        AttachedApp(
          id: id,
          uri: uri,
          discovery: deviceSerial == null
              ? AppDiscovery.byHand
              : AppDiscovery.deviceLog,
          reachability: AppReachability.unchecked,
          observedAt: _now(),
          label: label ?? deviceSerial ?? '${uri.host}:${uri.port}',
          sourcePath: deviceSerial,
        );
    _replace(row);
    _state = _registry.copyWith(lookedAt: _now());
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
      final link = await FlutterAppLink.attach(
        app.uri,
        connect: connect,
        now: _now,
      );
      final previous = _links[app.id];
      _links[app.id] = link;
      if (previous != null) unawaited(previous.dispose());
      unawaited(link.done.then((_) => _onLinkClosed(app.id, link)));
      final support = await link.widgetLocationSupport();
      if (!_open) {
        await link.dispose();
        return app;
      }
      final attached = app.copyWith(
        reachability: AppReachability.attached,
        observedAt: _now(),
        isolateId: link.isolateId,
        widgetLocations: support,
        reloadMethod: link.reloadMethod,
        restartMethod: link.restartMethod,
        clearDetail: true,
      );
      _replace(attached);
      link.servicesChanged.listen((_) => _refreshServices(app.id));
      return attached;
    } on FlutterAppException catch (error) {
      final failed = app.copyWith(
        reachability: AppReachability.unreachable,
        observedAt: _now(),
        detail: error.message,
        clearIsolate: true,
        clearServices: true,
      );
      _replace(failed);
      return failed;
    }
  }

  void _refreshServices(String id) {
    final link = _links[id];
    final app = _registry.byId(id);
    if (!_open || link == null || app == null) return;
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

  void _onLinkClosed(String id, FlutterAppLink link) {
    if (_links[id] != link) return;
    _links.remove(id);
    final app = _registry.byId(id);
    if (!_open || app == null) return;
    _replace(
      app.copyWith(
        reachability: AppReachability.ended,
        observedAt: _now(),
        detail: 'The app closed its VM service connection.',
        clearIsolate: true,
        clearServices: true,
      ),
    );
  }

  void _replace(AttachedApp app) {
    if (!_open) return;
    final apps = [
      for (final existing in _registry.apps)
        if (existing.id == app.id) app else existing,
    ];
    if (!apps.any((existing) => existing.id == app.id)) apps.add(app);
    _state = _registry.copyWith(apps: apps);
  }

  /// The app a caller meant, refusing rather than guessing.
  AttachedApp requireApp(String? id) {
    if (id != null && id.isNotEmpty) {
      final app = _registry.byId(id);
      if (app == null) {
        throw FlutterAppException(
          FlutterAppFailure.unknownApp,
          describeFlutterAppFailure(FlutterAppFailure.unknownApp, detail: id),
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
    final only = _registry.onlyAttached;
    if (only != null) return only;
    if (_registry.attached.isEmpty) {
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
        detail: _registry.attached.map((app) => app.id).join(', '),
      ),
    );
  }

  /// How an app becomes visible here, in one sentence.
  String get attachHint =>
      'A run this Karmashala server started and a "flutter run" started '
      'anywhere else on the server\'s machine are found on their own; an app '
      'on a phone plugged into a desktop reaches it through the Karmashala app '
      'on that desktop. A run on another machine still needs its address '
      'attached by hand.';

  FlutterAppLink _requireLink(String? id) {
    final app = requireApp(id);
    return _links[app.id] ??
        (throw FlutterAppException(
          FlutterAppFailure.disconnected,
          describeFlutterAppFailure(FlutterAppFailure.disconnected),
        ));
  }

  Future<void> hotReload(String? id) => _requireLink(id).hotReload();

  Future<void> hotRestart(String? id) => _requireLink(id).hotRestart();

  /// Closes the server's connection to [id] without touching the app.
  Future<void> detach(String id) async {
    await _links.remove(id)?.dispose();
    final app = _registry.byId(id);
    if (app == null) return;
    if (app.discovery == AppDiscovery.byHand) {
      _state = _registry.copyWith(
        apps: _registry.apps.where((e) => e.id != id).toList(),
      );
      return;
    }
    _replace(
      app.copyWith(
        reachability: AppReachability.unchecked,
        observedAt: _now(),
        clearIsolate: true,
        clearServices: true,
        clearDetail: true,
      ),
    );
  }

  /// Drops a row and, when it came from a file nothing answers on, the file.
  Future<void> forget(String id) async {
    final app = _registry.byId(id);
    await detach(id);
    final path = app?.sourcePath;
    if (path != null && app != null && !app.isAttached) {
      if (app.discovery == AppDiscovery.uriFile) await directory.forget(path);
    }
    _state = _registry.copyWith(
      apps: _registry.apps.where((e) => e.id != id).toList(),
    );
  }

  /// Everything the app printed, said and threw, newest last.
  List<AppLogRecord> console(
    String? id, {
    int limit = 200,
    Set<AppLogSource>? sources,
  }) {
    final app = requireApp(id);
    return _links[app.id]?.tail(limit: limit, sources: sources) ?? const [];
  }

  /// Arms widget-select mode, waits for the tap, and reads what was picked.
  Future<WidgetSelection> pickWidget(
    String? id, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final link = _requireLink(id);
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
    final subscription = link.navigations.listen((location) {
      if (!picked.isCompleted) picked.complete(location);
    });
    try {
      await link.setWidgetSelectMode(enabled: true);
      final location = await picked.future.timeout(timeout);
      final selection = await link.selectedWidget();
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
        _log('leaving select mode: ${error.message}');
      }
    }
  }

  /// Lets go of every link and daemon; the apps keep running.
  Future<void> close() async {
    _open = false;
    await _watch?.cancel();
    await _daemonWatch?.cancel();
    for (final daemon in _daemons.values.toList()) {
      await daemon.dispose();
    }
    _daemons.clear();
    for (final link in _links.values.toList()) {
      await link.dispose();
    }
    _links.clear();
  }
}

typedef _DaemonApp = ({DtdApp app, DtdInstance daemon});
