import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../protocol/companion_method.dart';

/// What a phone is told when what it asked needs the desktop app and no app is
/// connected to the session host.
const String kCompanionAppNotRunning =
    'the Karmashala app is not running; open it on the desktop for this';

/// The refusal for [kCompanionAppNotRunning]. `badRequest` because nothing was
/// withheld from this phone: the request is fine and the machine cannot do it
/// right now.
const RemoteApiRefusal companionAppNotRunning = RemoteApiRefusal(
  ErrorCode.badRequest,
  kCompanionAppNotRunning,
);

/// The session host's line to the desktop app it forwards companion calls to.
abstract interface class CompanionAppLink {
  /// Whether an app is connected and has said it answers companion calls.
  bool get connected;

  /// Runs [method] in the app with [arguments] and answers its result. Throws
  /// [RemoteApiRefusal] — [companionAppNotRunning] when no app is connected,
  /// or whatever the app refused with.
  Future<Map<String, Object?>> call(
    CompanionMethod method,
    Map<String, Object?> arguments,
  );
}
