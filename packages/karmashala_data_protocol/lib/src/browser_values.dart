import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_browser/browser.dart';

/// What the server's browser is doing (slice 3d), so every pane can say so.
enum BrowserStatus {
  /// No session. A browser may be open; the server is not attached to it.
  disconnected,

  /// Attaching or launching.
  connecting,

  /// Attached, idle.
  connected,

  /// Attached, with a command in flight.
  busy,

  /// Attached, waiting for somebody to click an element in the page.
  picking;

  static BrowserStatus? fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// One drivable tab.
final class BrowserTab {
  const BrowserTab({required this.id, required this.title, required this.url});

  final String id;
  final String title;
  final String url;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'url': url};

  static BrowserTab fromJson(Map<String, Object?> json) => BrowserTab(
    id: json['id']! as String,
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
  );
}

/// The Chrome the server drives over CDP, as it now stands. [headless] is a
/// server with no window to show one in: the pane shows screenshots, and
/// nothing can be picked by hand.
final class BrowserState {
  const BrowserState({
    this.status = BrowserStatus.disconnected,
    this.connection,
    this.port = 9222,
    this.url = '',
    this.title = '',
    this.error,
    this.tabs = const [],
    this.currentTargetId,
    this.headless = false,
  });

  final BrowserStatus status;

  /// How the server got hold of the browser, said verbatim.
  final String? connection;
  final int port;
  final String url;
  final String title;

  /// The last failure, in the browser taxonomy's words; cleared by the next
  /// thing that works.
  final String? error;
  final List<BrowserTab> tabs;
  final String? currentTargetId;
  final bool headless;

  bool get isConnected =>
      status != BrowserStatus.disconnected &&
      status != BrowserStatus.connecting;

  bool get isBusy =>
      status == BrowserStatus.connecting || status == BrowserStatus.busy;

  BrowserState copyWith({
    BrowserStatus? status,
    String? connection,
    String? url,
    String? title,
    String? error,
    List<BrowserTab>? tabs,
    String? currentTargetId,
    bool clearError = false,
  }) => BrowserState(
    status: status ?? this.status,
    connection: connection ?? this.connection,
    port: port,
    url: url ?? this.url,
    title: title ?? this.title,
    error: clearError ? null : (error ?? this.error),
    tabs: tabs ?? this.tabs,
    currentTargetId: currentTargetId ?? this.currentTargetId,
    headless: headless,
  );

  Map<String, Object?> toJson() => {
    'status': status.name,
    'connection': ?connection,
    'port': port,
    'url': url,
    'title': title,
    'error': ?error,
    'tabs': [for (final tab in tabs) tab.toJson()],
    'currentTargetId': ?currentTargetId,
    'headless': headless,
  };

  static BrowserState fromJson(Map<String, Object?> json) => BrowserState(
    status:
        BrowserStatus.fromName(json['status']) ??
        (throw const FormatException('not a browser status')),
    connection: json['connection'] as String?,
    port: json['port'] as int? ?? 9222,
    url: json['url'] as String? ?? '',
    title: json['title'] as String? ?? '',
    error: json['error'] as String?,
    tabs: [
      for (final tab in json['tabs'] as List? ?? const [])
        BrowserTab.fromJson((tab as Map).cast<String, Object?>()),
    ],
    currentTargetId: json['currentTargetId'] as String?,
    headless: json['headless'] == true,
  );

  bool sameAs(BrowserState other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

/// What a person picked in the page: the element, and where the server wrote
/// its picture — on the server's machine, where the agents that read it run.
final class BrowserPick {
  const BrowserPick(this.capture, {this.captureFile});

  final ElementCapture capture;
  final String? captureFile;

  /// The capture as prompt text, pointing an agent at the picture.
  String get promptText => captureFile == null
      ? capture.toPromptText()
      : '${capture.toPromptText()}\n\nScreenshot file: $captureFile';

  Map<String, Object?> toJson() => {
    'capture': capture.toJson(),
    'captureFile': ?captureFile,
  };

  static BrowserPick fromJson(Map<String, Object?> json) => BrowserPick(
    ElementCapture.fromJson((json['capture']! as Map).cast<String, Object?>()),
    captureFile: json['captureFile'] as String?,
  );
}

/// PNG bytes on the wire.
String pngToJson(Uint8List png) => base64Encode(png);

Uint8List pngFromJson(Object? json) => json is String
    ? base64Decode(json)
    : throw const FormatException('not a picture');
