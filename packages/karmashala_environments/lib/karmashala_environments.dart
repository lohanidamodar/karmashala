/// Where agents run and who they run as — environments, SSH hosts and the
/// host keys trusted for them, agent installations, saved accounts and the
/// usage history: the values' wire shape and the rules every copy follows.
/// The tables are `store.dart`'s, which only the server imports.
library;

export 'src/environment_rules.dart';
export 'src/installation_rules.dart';
export 'src/usage_rules.dart';
export 'src/values_json.dart';
export 'ssh.dart';
