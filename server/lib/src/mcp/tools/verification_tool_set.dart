import 'package:karmashala_verification/tools.dart';

import 'server_tool_set.dart';
import 'server_verification_runs.dart';
import 'verification_tool_schemas.dart';

/// `verification_*`, all of it the server's: a review of a change, a page on
/// its browser (slice 3d) and a device on its machine (slice 4a) are recorded
/// here, and every run is read here. Nothing is handed to the app.
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
  ) => runTool(
    () => VerificationTools(
      runs,
      callerSessionId: callerSessionId,
    ).call(tool, arguments),
  );
}
