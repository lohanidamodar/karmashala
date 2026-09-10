/// Why an operation against a running Flutter app failed. A caller reacts to
/// the kind, never to a string: "something went wrong" must not reach the UI.
enum FlutterAppFailure {
  /// Nothing is attached, so there is nothing to act on.
  noAppAttached,

  /// A caller named an app that is not in the registry.
  unknownApp,

  /// Two or more apps are attached and the caller named none of them.
  ambiguousApp,

  /// The address is not a VM service address.
  badUri,

  /// We opened a socket and it was refused, or `getVM` never answered.
  connectFailed,

  /// The connection closed while we were using it.
  disconnected,

  /// Reachable, but no Flutter tool is attached to recompile for us — so hot
  /// reload cannot be asked for.
  notToolDriven,

  /// The app does not serve a service extension we need — in practice a
  /// profile or release build, where the inspector is compiled out.
  extensionMissing,

  /// The user left widget-select mode without picking anything.
  pickCancelled,

  /// A pick, or a call, ran out of time.
  timeout,

  /// A reply arrived and was not shaped the way the protocol promises.
  malformedResponse,
}

/// The single exception type raised by everything under `features/flutter_apps`.
class FlutterAppException implements Exception {
  const FlutterAppException(this.failure, this.message, {this.cause});

  final FlutterAppFailure failure;

  /// User-facing and actionable.
  final String message;

  final Object? cause;

  @override
  String toString() => 'FlutterAppException(${failure.name}): $message';
}

/// Standard, actionable wording for each failure kind. [attachHint] is the
/// `--vmservice-out-file` sentence, which only the caller knows the path for.
String describeFlutterAppFailure(
  FlutterAppFailure failure, {
  String? detail,
  String? attachHint,
}) {
  final suffix = detail == null || detail.isEmpty ? '' : ' ($detail)';
  final hint = attachHint == null || attachHint.isEmpty ? '' : ' $attachHint';
  return switch (failure) {
    FlutterAppFailure.noAppAttached =>
      'No running Flutter app is attached.$hint$suffix',
    FlutterAppFailure.unknownApp =>
      'No app with that id is on record. Ask for the list again — an app id '
          'lasts only as long as the run that produced it.$suffix',
    FlutterAppFailure.ambiguousApp =>
      'More than one Flutter app is attached, so name the one you mean.$suffix',
    FlutterAppFailure.badUri =>
      'That is not a Dart VM service address. It looks like '
          '"http://127.0.0.1:53119/AbCdEf=/" — the line "flutter run" prints '
          'as "A Dart VM Service on … is available at:".$suffix',
    FlutterAppFailure.connectFailed =>
      'Nothing answered on that address. The app it belonged to has probably '
          'stopped; a VM service address is good only for the run that printed '
          'it.$suffix',
    FlutterAppFailure.disconnected =>
      'The app closed its VM service connection.$suffix',
    FlutterAppFailure.notToolDriven =>
      'This app is reachable but no Flutter tool is attached to it, so there '
          'is nothing to recompile the sources. Hot reload comes from the '
          '"flutter run" that owns the process, not from the VM service.$suffix',
    FlutterAppFailure.extensionMissing =>
      'This build does not serve that service extension. The widget inspector '
          'is compiled out of profile and release builds — run the app in '
          'debug mode.$suffix',
    FlutterAppFailure.pickCancelled =>
      'Widget-select mode was left without a widget being picked.$suffix',
    FlutterAppFailure.timeout => 'The app did not answer in time.$suffix',
    FlutterAppFailure.malformedResponse =>
      'The app answered in a shape this protocol does not describe.$suffix',
  };
}
