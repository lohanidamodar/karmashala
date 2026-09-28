import 'package:path/path.dart' as p;

import '../../util/clock.dart';
import '../claude_code/claude_auth_service.dart' show ClaudeKeychainCache;
import '../data/auth_file_io.dart';
import '../data/usage_http.dart';
import '../domain/agent_usage.dart';

/// Everything one usage reading may need from the host.
class UsageReadContext {
  const UsageReadContext({
    required this.storeHome,
    required this.paths,
    required this.localMacHost,
    required this.http,
    required this.clock,
    required this.keychain,
    required this.io,
    this.homeFromVariable = false,
  });

  /// The agent's store home in the installation's environment, spelled so [io]
  /// reaches it, or null when the environment has none for it — each
  /// endpoint says so in its own words.
  final String? storeHome;

  /// The path rules [storeHome] is spelled in — joining a POSIX home with the
  /// Windows context names a file that cannot exist.
  final p.Context paths;

  /// Whether the store is this machine's and this machine is a Mac, where a
  /// CLI may keep its credential in the login Keychain instead of a file.
  final bool localMacHost;

  /// Reads the files under [storeHome] wherever they are — on this host, or
  /// over the runner of the SSH host that holds them.
  final AuthFileIo io;

  /// Whether the environment moved [storeHome] with the agent's own variable
  /// (`AgentStoreSpec.homeVariable`) rather than it being the default.
  final bool homeFromVariable;

  final UsageHttp http;
  final Clock clock;

  /// The memo in front of the macOS Keychain, shared by every reader of it.
  final ClaudeKeychainCache keychain;
}

/// **Where an agent's usage reading comes from**: the same endpoint the
/// vendor's own app asks, authorised with the token the installation already
/// stores. Throws `UsageException` on any failure.
abstract interface class AgentUsageEndpoint {
  Future<AgentUsage> read(UsageReadContext context);
}
