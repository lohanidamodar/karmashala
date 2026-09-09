import 'vm_service_uri.dart';

/// How we came to know about a VM service address.
///
/// Kept on the record because it decides what a failure to reach it *means*: a
/// file `flutter run` wrote is evidence a Flutter app started here, while an
/// address a person typed is evidence of nothing but their intent.
enum AppDiscovery {
  /// A `--vmservice-out-file` left in the directory this app watches. Only
  /// runs Karmashala started write one; nothing asks a user to add the flag.
  uriFile,

  /// A Dart Tooling Daemon on this machine named it. Every `flutter run`
  /// starts one and it records its own address on disk, so this is the reader
  /// that finds a run started in somebody else's terminal.
  toolingDaemon,

  /// The Dart VM announced it in a device log and an `adb forward` made it
  /// reachable from here.
  deviceLog,

  /// Typed or pasted by the user, or handed over by an agent through
  /// `flutter_attach`.
  byHand,
}

/// Whether we can reach a VM service, and whether we have tried.
///
/// Four values, for the same reason `ExecutableReachability` has four
/// (`package:karmashala_core/paths.dart`): "nothing answered" and "we did not ask" are
/// opposite instructions to the reader, and collapsing them is the §19 mistake
/// of reporting a reading that was never taken as a reading of zero.
enum AppReachability {
  /// Attached now. The socket is open and `getVM` answered.
  attached,

  /// We asked and nothing answered. For a [AppDiscovery.uriFile] address this
  /// means an app *was* started here and has since stopped, or its VM service
  /// is not reachable from this process — those two are indistinguishable from
  /// outside, and the wording says so rather than picking one.
  unreachable,

  /// We know the address and have not tried it.
  unchecked,

  /// We were attached and the socket closed under us. Distinct from
  /// [unreachable] because it is an *observation of the app ending*, not a
  /// failed guess: something was definitely there.
  ended,
}

/// Whether a build carries `creationLocation` data for its widgets.
///
/// `--track-widget-creation` is on by default in debug and absent in release
/// and profile, so a picked widget in a release build has a description and no
/// file. Three values because "we could not ask" is not "there is none": the
/// first is our blind spot, the second is a fact about the build.
enum WidgetLocationSupport {
  /// `ext.flutter.inspector.isWidgetCreationTracked` answered `true`.
  tracked,

  /// It answered `false`. A pick will name the widget and cannot name a line.
  absent,

  /// It was not asked, or did not answer.
  unknown,
}

/// One VM service address the app knows about, and what we last established
/// about it.
///
/// Immutable, and every reading on it carries [observedAt] so the panel can say
/// how old it is (§19's second rule). Nothing here is persisted — see
/// `AttachedApps` for why a stored VM service URI is state that rots.
class AttachedApp {
  const AttachedApp({
    required this.id,
    required this.uri,
    required this.discovery,
    required this.reachability,
    required this.observedAt,
    this.label,
    this.sourcePath,
    this.isolateId,
    this.detail,
    this.widgetLocations = WidgetLocationSupport.unknown,
    this.reloadMethod,
    this.restartMethod,
  });

  /// Stable for the life of one `flutter run`: the authority and the auth
  /// token, which is what makes a second discovery of the same app the same
  /// row rather than a duplicate.
  final String id;

  /// The `ws://…/ws` address. Never written to disk.
  final Uri uri;

  final AppDiscovery discovery;
  final AppReachability reachability;

  /// When [reachability] was established.
  final DateTime observedAt;

  /// What to call it on screen — the app's own isolate name once attached,
  /// the file's basename before that.
  final String? label;

  /// Where this came from, when there is a path to name: the
  /// `--vmservice-out-file`, or the project a tooling daemon was started in.
  /// Kept so a stale row can be pointed at, and forgotten, by name.
  final String? sourcePath;

  /// The main isolate, which every service extension call needs. Null unless
  /// attached.
  final String? isolateId;

  /// Why it is not reachable, in the words the user should read.
  final String? detail;

  final WidgetLocationSupport widgetLocations;

  /// The method names `flutter_tools` registered on *this* connection for hot
  /// reload and hot restart — `s1.reloadSources` and `s1.hotRestart` on the
  /// owner's machine, 2026-09-08.
  ///
  /// **Never hardcode the prefix.** The Dart Development Service numbers the
  /// registering client per connection, so the same app is `s0.reloadSources`
  /// to `flutter run`'s own client and `s1.reloadSources` to ours. Guessing
  /// `s0.` produced a request that was accepted and then never answered — a
  /// hang, not an error. The names arrive on the `Service` stream as
  /// `ServiceRegistered` events, which DDS replays to a new subscriber, so
  /// reading them is a subscription rather than a poll.
  final String? reloadMethod;
  final String? restartMethod;

  bool get isAttached => reachability == AppReachability.attached;

  /// Whether a Flutter tool is attached to this app and will recompile for us.
  ///
  /// Hot reload is not something the VM service does on its own: the reload
  /// needs the frontend server that `flutter run` owns, and the only way to
  /// ask for it is the service *it* registered. An app started without the
  /// tool — `flutter attach` gone, a release-mode `dart run`, a process the
  /// user launched by hand — is reachable and cannot be reloaded, and that is
  /// a different sentence from "not attached".
  bool get canHotReload => isAttached && reloadMethod != null;

  /// The printed form, for showing to a human who has the terminal open.
  String get printedUri => describeVmServiceUri(uri);

  AttachedApp copyWith({
    Uri? uri,
    AppReachability? reachability,
    DateTime? observedAt,
    String? label,
    String? sourcePath,
    String? isolateId,
    String? detail,
    WidgetLocationSupport? widgetLocations,
    String? reloadMethod,
    String? restartMethod,
    bool clearDetail = false,
    bool clearIsolate = false,
    bool clearServices = false,
  }) => AttachedApp(
    id: id,
    uri: uri ?? this.uri,
    discovery: discovery,
    reachability: reachability ?? this.reachability,
    observedAt: observedAt ?? this.observedAt,
    label: label ?? this.label,
    sourcePath: sourcePath ?? this.sourcePath,
    isolateId: clearIsolate ? null : (isolateId ?? this.isolateId),
    detail: clearDetail ? null : (detail ?? this.detail),
    widgetLocations: widgetLocations ?? this.widgetLocations,
    reloadMethod: clearServices ? null : (reloadMethod ?? this.reloadMethod),
    restartMethod: clearServices ? null : (restartMethod ?? this.restartMethod),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'vmServiceUri': uri.toString(),
    'printedUri': printedUri,
    'discoveredBy': discovery.name,
    if (sourcePath != null) 'sourceFile': sourcePath,
    'reachability': reachability.name,
    'observedAt': observedAt.toIso8601String(),
    if (isolateId != null) 'isolateId': isolateId,
    if (detail != null) 'detail': detail,
    'widgetLocations': widgetLocations.name,
    'canHotReload': canHotReload,
  };

  /// Derives the row id for [uri]: authority plus the auth-token path, without
  /// the `/ws` suffix.
  ///
  /// The port alone is not enough — a port is reused within minutes of a run
  /// ending — and the whole URI is too much, because the same app reached as
  /// `http://…/` and `ws://…/ws` must be one row.
  static String idFor(Uri uri) {
    var path = uri.path;
    if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
    return '${uri.authority}$path';
  }
}
