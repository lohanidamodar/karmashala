import 'package:karmashala_mcp/instructions.dart';

import 'server_tool_set.dart';

/// `instructions`: the operating guides, which need nothing but themselves.
class InstructionsToolSet extends ServerToolSet {
  const InstructionsToolSet();

  @override
  List<Map<String, Object?>> get schemas => instructionsToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() => const InstructionsTools().call(tool, arguments));
}
