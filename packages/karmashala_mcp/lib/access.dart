/// How an agent reaches these tools, and whether it can: the config entry it
/// is handed, the address a WSL agent dials, the permissions on the file the
/// credential is published in, and a real handshake with the compiled bridge.
library;

export 'src/handshake_file_permissions.dart';
export 'src/launcher_mcp.dart';
export 'src/mcp_bridge_probe.dart';
export 'src/wsl_host_address.dart';
