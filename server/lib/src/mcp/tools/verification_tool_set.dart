import 'package:karmashala_verification/tools.dart';

import 'server_tool_set.dart';
import 'server_verification_runs.dart';
import 'verification_tool_schemas.dart';

/// `verification_*`: a review of a change, and a page on the server's own
/// browser (slice 3d), are recorded here, and every run is read here. A
/// device run drives a device on the app's machine, so its start is handed
/// to the app — and so are `note`, `finish` and a `get` with no id while this
/// server records nothing, since the run they mean is then the app's.
///
/// Known gap: the server cannot see a device run the app holds, so a run can
/// be started here beside one (the app still refuses the reverse only for
/// its own slot; this server refuses any start while it records).
class VerificationToolSet extends ServerToolSet {
  VerificationToolSet(this.runs);

  final ServerVerificationRuns runs;

  @override
  List<Map<String, Object?>> get schemas => verificationToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    final here = switch (tool) {
      'verification_start' => runs.isRecording || !_drivesTheApp(arguments),
      'verification_note' || 'verification_finish' => runs.isRecording,
      'verification_get' => _text(arguments['id']) != null || runs.isRecording,
      _ => true,
    };
    if (!here) return null;
    return runTool(
      () => VerificationTools(
        runs,
        callerSessionId: callerSessionId,
      ).call(tool, arguments),
    );
  }

  /// A device and nothing else: the one run only the app can drive. Anything
  /// else is a change or a page run, or a refusal, all answered here.
  static bool _drivesTheApp(Map<String, dynamic> arguments) {
    if (arguments['change'] == true) return false;
    final url = _text(arguments['url']) != null;
    final serial = _text(arguments['serial']) != null;
    return serial && !url;
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;
}
