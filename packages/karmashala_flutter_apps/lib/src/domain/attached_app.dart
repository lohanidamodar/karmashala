import 'vm_service_uri.dart';

/// How we came to know about a VM service address — it decides what a failure
/// to reach it means: a file `flutter run` wrote is evidence, a typed one is not.
enum AppDiscovery {
  /// A `--vmservice-out-file` left in the directory this app watches. Only
  /// runs Karmashala started write one; nothing asks a user to add the flag.
  uriFile,

  /// A Dart Tooling Daemon on this machine named it — how a run started in
  /// somebody else's terminal is found.
  toolingDaemon,

  /// The Dart VM announced it in a device log and an `adb forward` made it
  /// reachable from here.
  deviceLog,

  /// Typed or pasted by the user, or handed over by an agent through
  /// `flutter_attach`.
  byHand,
}

/// Whether we can reach a VM service, and whether we have tried. Four values
/// because "nothing answered" and "we did not ask" are opposite instructions.
enum AppReachability {
  /// Attached now. The socket is open and `getVM` answered.
  attached,

  /// We asked and nothing answered. "The app stopped" and "not reachable from
  /// here" are indistinguishable from outside, and the wording says so.
  unreachable,

  /// We know the address and have not tried it.
  unchecked,

  /// We were attached and the socket closed under us — an observation of the
  /// app ending, not a failed guess.
  ended,
}

/// Whether a build carries `creationLocation` data for its widgets. Three
/// values because "we could not ask" is not "there is none".
enum WidgetLocationSupport {
  /// `ext.flutter.inspector.isWidgetCreationTracked` answered `true`.
  tracked,

  /// It answered `false`. A pick will name the widget and cannot name a line.
  absent,

  /// It was not asked, or did not answer.
  unknown,
}

/// One VM service address the app knows about, and what we last established
/// about it. Nothing here is persisted: a stored VM service URI rots.
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

  /// Stable for the life of one `flutter run` — authority plus auth token — so
  /// a second discovery of the same app is the same row.
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

  /// Where this came from when there is a path to name, so a stale row can be
  /// pointed at, and forgotten, by name.
  final String? sourcePath;

  /// The main isolate, which every service extension call needs. Null unless
  /// attached.
  final String? isolateId;

  /// Why it is not reachable, in the words the user should read.
  final String? detail;

  final WidgetLocationSupport widgetLocations;

  /// Reload/restart method names as registered on *this* connection: never
  /// hardcode the `s0.`/`s1.` prefix — a guessed one hangs instead of erroring.
  final String? reloadMethod;
  final String? restartMethod;

  bool get isAttached => reachability == AppReachability.attached;

  /// Whether a Flutter tool is attached and will recompile for us: the reload
  /// needs the frontend server `flutter run` owns, so reachable ≠ reloadable.
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

  /// The row id for [uri]: authority plus auth-token path, without `/ws`. A
  /// port alone is reused within minutes; the whole URI splits one app in two.
  static String idFor(Uri uri) {
    var path = uri.path;
    if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
    return '${uri.authority}$path';
  }
}
