import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';

import 'ssh_host.dart';
import 'ssh_host_key.dart';

/// The rules for environments, SSH hosts and trusted host keys that every
/// copy follows: the tables' orders (so a client's copy lists rows as the
/// store does) and what a row must be before the server writes it.

/// `execution_environments ORDER BY created_at, id`.
int compareEnvironments(ExecutionEnvironment a, ExecutionEnvironment b) =>
    _byCreation(a.createdAt, a.id, b.createdAt, b.id);

/// `ssh_hosts ORDER BY created_at, id`.
int compareSshHosts(SshHost a, SshHost b) =>
    _byCreation(a.createdAt, a.id, b.createdAt, b.id);

/// `ssh_known_hosts ORDER BY host, port`.
int compareKnownHosts(KnownHostKey a, KnownHostKey b) {
  final byHost = a.host.compareTo(b.host);
  return byHost != 0 ? byHost : a.port.compareTo(b.port);
}

/// `agent_installations ORDER BY created_at, id`.
int compareInstallations(AgentInstallation a, AgentInstallation b) =>
    _byCreation(a.createdAt, a.id, b.createdAt, b.id);

/// `claude_accounts ORDER BY email, organization_name` (SQLite sorts a null
/// name first).
int compareClaudeAccounts(ClaudeAccount a, ClaudeAccount b) {
  final byEmail = a.email.compareTo(b.email);
  if (byEmail != 0) return byEmail;
  return _nullsFirst(a.organizationName, b.organizationName);
}

/// `codex_accounts ORDER BY email, account_id` (a null email first).
int compareCodexAccounts(CodexAccount a, CodexAccount b) {
  final byEmail = _nullsFirst(a.email, b.email);
  return byEmail != 0 ? byEmail : a.accountId.compareTo(b.accountId);
}

int _byCreation(DateTime a, String aId, DateTime b, String bId) {
  final byTime = a.compareTo(b);
  return byTime != 0 ? byTime : aId.compareTo(bId);
}

int _nullsFirst(String? a, String? b) {
  if (a == null) return b == null ? 0 : -1;
  if (b == null) return 1;
  return a.compareTo(b);
}

/// Why [environment] cannot be recorded as a discovered environment, or null.
/// The local host is `windows` whatever it runs; a WSL distribution is
/// `wsl:<distribution>`; an SSH environment is never written on its own — it
/// is its host's, written with it.
String? environmentProblem(ExecutionEnvironment environment) {
  if (environment.id.trim().isEmpty) return 'An environment needs an id.';
  if (environment.name.trim().isEmpty) return 'An environment needs a name.';
  switch (environment.kind) {
    case EnvironmentKind.windowsNative:
    case EnvironmentKind.localPosix:
      if (environment.id != localHostEnvironmentId) {
        return 'This machine is the environment "$localHostEnvironmentId", '
            'not "${environment.id}".';
      }
    case EnvironmentKind.wsl:
      final distribution = environment.wslDistribution;
      if (distribution == null || distribution.trim().isEmpty) {
        return 'A WSL environment names its distribution.';
      }
      if (environment.id != 'wsl:$distribution') {
        return 'The WSL distribution $distribution is the environment '
            '"wsl:$distribution", not "${environment.id}".';
      }
    case EnvironmentKind.ssh:
      return 'An SSH environment is saved with its host.';
  }
  return null;
}

/// Why [host] cannot be saved, or null. Nothing here judges a credential:
/// the row holds none — a password is asked per connection and a key is
/// read from the file [SshHost.privateKey] names, on a machine of this
/// client's own (never another SSH host).
String? sshHostProblem(SshHost host) {
  if (host.id.trim().isEmpty) return 'An SSH host needs an id.';
  if (host.name.trim().isEmpty) return 'An SSH host needs a name.';
  final address = host.host.trim();
  if (address.isEmpty) return 'An SSH host needs an address.';
  if (address != host.host || address.contains(RegExp(r'\s'))) {
    return 'An SSH address has no spaces in it.';
  }
  if (host.port < 1 || host.port > 65535) {
    return 'An SSH port is between 1 and 65535, not ${host.port}.';
  }
  final user = host.username.trim();
  if (user.isEmpty) return 'An SSH host needs a user name.';
  if (user != host.username || user.contains(RegExp(r'\s'))) {
    return 'An SSH user name has no spaces in it.';
  }
  final key = host.privateKey;
  switch (host.authMethod) {
    case SshAuthMethod.privateKey:
      if (key == null || key.path.trim().isEmpty) {
        return 'Key authentication needs the private key\'s location.';
      }
      if (key.environmentId.startsWith('ssh:')) {
        return 'The private key is read from this machine or WSL, '
            'not from another SSH host.';
      }
    case SshAuthMethod.password:
      if (key != null) {
        return 'Password authentication keeps no key location.';
      }
  }
  final directory = host.defaultDirectory;
  if (directory != null && directory.environmentId != host.environmentId) {
    return 'The starting directory is a path on the host itself.';
  }
  return null;
}

/// Why [key] cannot be trusted, or null — before looking at what is already
/// trusted for its `host:port` ([trustProblem]).
String? knownHostProblem(KnownHostKey key) {
  if (key.host.trim().isEmpty) return 'A trusted key names its host.';
  if (key.port < 1 || key.port > 65535) {
    return 'An SSH port is between 1 and 65535, not ${key.port}.';
  }
  if (key.keyType.trim().isEmpty) return 'A trusted key names its type.';
  if (!key.fingerprint.startsWith('SHA256:') ||
      key.fingerprint.length <= 'SHA256:'.length) {
    return 'A trusted key is recorded by its SHA256 fingerprint.';
  }
  return null;
}

/// The host-key rule behind every trust decision: a key is trusted only
/// where nothing is, or where the same key already is. **A different key
/// for a `host:port` already trusted is refused** — the man-in-the-middle
/// signal is never overwritten by a trust; forgetting the old key first is
/// the one deliberate way to replace it.
String? trustProblem(KnownHostKey? trusted, KnownHostKey key) {
  if (trusted == null) return null;
  if (trusted.fingerprint == key.fingerprint &&
      trusted.keyType == key.keyType) {
    return null;
  }
  return 'A different ${trusted.keyType} key (${trusted.fingerprint}) is '
      'trusted for ${key.host}:${key.port}. Forget it first if the host '
      'was rebuilt.';
}

/// [account] without its token bundle or identity record — what a list of
/// saved accounts and a change told to other clients carry.
ClaudeAccount claudeAccountWithoutCredentials(ClaudeAccount account) =>
    ClaudeAccount(
      id: account.id,
      email: account.email,
      organizationUuid: account.organizationUuid,
      organizationName: account.organizationName,
      subscriptionType: account.subscriptionType,
      rateLimitTier: account.rateLimitTier,
      capturedEnvironmentId: account.capturedEnvironmentId,
      capturedAt: account.capturedAt,
      claudeAiOauth: const {},
    );

/// [account] without its `auth.json` bundle.
CodexAccount codexAccountWithoutCredentials(CodexAccount account) =>
    CodexAccount(
      id: account.id,
      accountId: account.accountId,
      email: account.email,
      planType: account.planType,
      capturedEnvironmentId: account.capturedEnvironmentId,
      capturedAt: account.capturedAt,
      auth: const {},
    );

/// Why [account] cannot be saved, or null.
String? claudeAccountProblem(ClaudeAccount account) {
  if (account.id.trim().isEmpty) return 'A saved account needs an id.';
  if (account.email.trim().isEmpty) return 'A saved account needs an email.';
  if (account.claudeAiOauth.isEmpty) {
    return 'A saved Claude account carries its sign-in.';
  }
  return null;
}

/// Why [account] cannot be saved, or null.
String? codexAccountProblem(CodexAccount account) {
  if (account.id.trim().isEmpty) return 'A saved account needs an id.';
  if (account.accountId.trim().isEmpty) {
    return 'A saved Codex account needs its account id.';
  }
  if (account.auth.isEmpty) return 'A saved Codex account carries its sign-in.';
  return null;
}
