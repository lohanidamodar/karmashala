import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart';

import 'github_hosts.dart';

/// Where a GitHub token came from, in the order they are tried.
enum GithubTokenSource { settings, environment, gh }

/// A token for one host. Its [toString] never prints [value].
class GithubToken {
  const GithubToken({
    required this.host,
    required this.value,
    required this.source,
    this.variable,
    this.account,
  });

  final String host;
  final String value;
  final GithubTokenSource source;

  /// The environment variable it was read from, for [GithubTokenSource.environment].
  final String? variable;

  /// The gh account it belongs to, for [GithubTokenSource.gh].
  final String? account;

  /// What a cache or a rate budget is kept under; never the token itself.
  String get key => githubTokenKey(host, value);

  @override
  String toString() => 'GithubToken($host, ${source.name})';
}

/// What the person chose for one host in Settings.
class GithubHostChoice {
  const GithubHostChoice({this.account, this.off = false});

  /// The gh account to use on the host; null uses gh's active one.
  final String? account;

  /// Karmashala does not use GitHub on this host at all.
  final bool off;

  static const GithubHostChoice none = GithubHostChoice();

  Map<String, Object?> toJson() => {'account': ?account, if (off) 'off': true};

  static GithubHostChoice fromJson(Object? json) {
    if (json is! Map) return none;
    final account = json['account'];
    return GithubHostChoice(
      account: account is String && account.isNotEmpty ? account : null,
      off: json['off'] == true,
    );
  }
}

/// One account `gh auth status --json hosts` lists.
class GhAccount {
  const GhAccount({
    required this.host,
    required this.login,
    required this.active,
    required this.ok,
  });

  final String host;
  final String login;

  /// gh's active account on [host].
  final bool active;

  /// gh's own check of the stored token passed.
  final bool ok;
}

/// The accounts gh holds, or why it could not say.
class GhAccountsReading {
  const GhAccountsReading(this.accounts, {this.problem});

  final List<GhAccount> accounts;

  /// Set when gh could not list them: not installed, too old, or failed.
  final String? problem;
}

/// Asks the `gh` CLI for a login; only ever a token source.
abstract interface class GhLogin {
  /// `gh auth token --hostname <host> [--user <account>]`, or null.
  Future<String?> token(String host, {String? account});

  Future<GhAccountsReading> accounts();
}

/// Tokens pasted in Settings, by host.
abstract interface class GithubSavedTokens {
  String? tokenFor(String host);
}

/// No token saved for any host.
class NoSavedGithubTokens implements GithubSavedTokens {
  const NoSavedGithubTokens();

  @override
  String? tokenFor(String host) => null;
}

/// Where a host's GitHub access comes from, for the Settings status line.
class GithubAccessReading {
  const GithubAccessReading({
    required this.host,
    this.source,
    this.variable,
    this.login,
    this.off = false,
  });

  final String host;

  /// Null when there is no token for [host].
  final GithubTokenSource? source;
  final String? variable;
  final String? login;
  final bool off;

  /// The plain sentence the Settings page shows.
  String get describe {
    if (off) return 'GitHub is turned off for $host';
    return switch (source) {
      GithubTokenSource.settings =>
        login == null
            ? 'Using your saved token'
            : 'Using your saved token as @$login',
      GithubTokenSource.environment =>
        'Using ${variable ?? 'a token'} from the server\'s environment',
      GithubTokenSource.gh =>
        login == null ? 'Using gh' : 'Using gh as @$login',
      null => 'No GitHub access: paste a token or run gh auth login',
    };
  }
}

/// Raised when there is no token Karmashala may use for a host.
class GithubNoAccess implements Exception {
  GithubNoAccess(this.host, {this.off = false});

  final String host;
  final bool off;

  String get message => off
      ? 'GitHub is turned off for $host in Settings → Source control → GitHub.'
      : 'No GitHub access for $host: paste a token in Settings → Source '
            'control → GitHub, or run "gh auth login" on the server\'s machine.';

  @override
  String toString() => message;
}

/// How long a token read from gh is used before gh is asked again, so a
/// `gh auth switch` takes effect soon.
const Duration kGhTokenFresh = Duration(minutes: 3);

/// The one place a GitHub token is chosen: a token saved in Settings, then
/// the server's environment, then gh's login. Callers ask by host and get a
/// [GithubToken] or nothing.
class GithubCredentials {
  GithubCredentials({
    required this.saved,
    this.environment = const {},
    this.gh,
    GithubHostChoice Function(String host)? choiceOf,
    DateTime Function()? now,
    this.ghFresh = kGhTokenFresh,
  }) : _choiceOf = choiceOf ?? _noChoice,
       _now = now ?? DateTime.now;

  final GithubSavedTokens saved;
  final GhLogin? gh;
  final Duration ghFresh;

  /// The server's environment, read for `GH_TOKEN` and its kin.
  final Map<String, String> environment;
  final GithubHostChoice Function(String host) _choiceOf;
  final DateTime Function() _now;
  final Map<String, ({String? token, DateTime at})> _ghKept = {};

  static GithubHostChoice _noChoice(String _) => GithubHostChoice.none;

  /// The token for [host], or null — also null when the host is turned off.
  Future<GithubToken?> tokenFor(String rawHost) async {
    final host = normalizeGithubHost(rawHost);
    if (host == null) return null;
    final choice = _choiceOf(host);
    if (choice.off) return null;
    final pasted = saved.tokenFor(host);
    if (pasted != null && pasted.isNotEmpty) {
      return GithubToken(
        host: host,
        value: pasted,
        source: GithubTokenSource.settings,
      );
    }
    if (environmentTokenFor(host) case final fromEnvironment?) {
      return fromEnvironment;
    }
    final account = choice.account;
    final fromGh = await _ghToken(host, account);
    if (fromGh == null) return null;
    return GithubToken(
      host: host,
      value: fromGh,
      source: GithubTokenSource.gh,
      account: account,
    );
  }

  /// [tokenFor], or [GithubNoAccess] naming why there is none.
  Future<GithubToken> requireTokenFor(String rawHost) async {
    final host = normalizeGithubHost(rawHost) ?? rawHost;
    final token = await tokenFor(host);
    if (token != null) return token;
    throw GithubNoAccess(host, off: _choiceOf(host).off);
  }

  /// `GH_TOKEN` / `GITHUB_TOKEN` for github.com and `*.ghe.com`, as gh reads
  /// them; `GH_ENTERPRISE_TOKEN` / `GITHUB_ENTERPRISE_TOKEN` only for the
  /// Enterprise Server `GH_HOST` names.
  GithubToken? environmentTokenFor(String host) {
    String? read(String name) {
      final value = environment[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    if (!isGithubEnterpriseServer(host)) {
      for (final name in const ['GH_TOKEN', 'GITHUB_TOKEN']) {
        if (read(name) case final value?) {
          return GithubToken(
            host: host,
            value: value,
            source: GithubTokenSource.environment,
            variable: name,
          );
        }
      }
      return null;
    }
    if (normalizeGithubHost(environment['GH_HOST']) != host) return null;
    for (final name in const [
      'GH_ENTERPRISE_TOKEN',
      'GITHUB_ENTERPRISE_TOKEN',
    ]) {
      if (read(name) case final value?) {
        return GithubToken(
          host: host,
          value: value,
          source: GithubTokenSource.environment,
          variable: name,
        );
      }
    }
    return null;
  }

  Future<String?> _ghToken(String host, String? account) async {
    final login = gh;
    if (login == null) return null;
    final key = '$host ${account ?? ''}';
    final kept = _ghKept[key];
    final now = _now();
    if (kept != null && now.difference(kept.at) < ghFresh) return kept.token;
    String? token;
    try {
      token = await login.token(host, account: account);
    } on Object {
      token = null;
    }
    if (token != null && token.trim().isEmpty) token = null;
    _ghKept[key] = (token: token?.trim(), at: now);
    return token?.trim();
  }

  /// Drops what was read from gh, so the next ask reads it again.
  void forgetGh() => _ghKept.clear();

  /// Where [host]'s access comes from now. [savedLogin] is the login a
  /// Settings token last tested as; [ghAccounts] names gh's active account.
  Future<GithubAccessReading> describe(
    String rawHost, {
    String? savedLogin,
    List<GhAccount> ghAccounts = const [],
  }) async {
    final host = normalizeGithubHost(rawHost) ?? rawHost;
    if (_choiceOf(host).off) return GithubAccessReading(host: host, off: true);
    final token = await tokenFor(host);
    if (token == null) return GithubAccessReading(host: host);
    String? login;
    if (token.source == GithubTokenSource.settings) login = savedLogin;
    if (token.source == GithubTokenSource.gh) {
      login =
          token.account ??
          ghAccounts
              .where((a) => a.host == host && a.active)
              .map((a) => a.login)
              .firstOrNull;
    }
    return GithubAccessReading(
      host: host,
      source: token.source,
      variable: token.variable,
      login: login,
    );
  }
}

/// gh on the first of [places] that has it: on a Windows server the login
/// often lives in a WSL distribution rather than beside the server.
class GhCommandLogin implements GhLogin {
  GhCommandLogin(this.places);

  /// Where gh is looked for, in order.
  final List<CommandRunner> Function() places;

  static const Duration _timeout = Duration(seconds: 20);

  Future<CommandResult?> _run(List<String> arguments) async {
    for (final runner in places()) {
      final CommandResult result;
      try {
        result = await runner.run(
          CommandRequest(
            executable: 'gh',
            arguments: arguments,
            timeout: _timeout,
          ),
        );
      } on CommandException {
        continue;
      }
      if (result.exitCode == 127) continue;
      return result;
    }
    return null;
  }

  @override
  Future<String?> token(String host, {String? account}) async {
    final result = await _run([
      'auth',
      'token',
      '--hostname',
      host,
      if (account != null) ...['--user', account],
    ]);
    if (result == null || !result.ok) return null;
    final token = result.stdout.trim();
    return token.isEmpty || token.contains(RegExp(r'\s')) ? null : token;
  }

  @override
  Future<GhAccountsReading> accounts() async {
    final result = await _run(const ['auth', 'status', '--json', 'hosts']);
    if (result == null) {
      return const GhAccountsReading(
        [],
        problem: 'gh is not installed on the server\'s machine.',
      );
    }
    final said = '${result.stdout}\n${result.stderr}'.toLowerCase();
    if (said.contains('unknown flag') || said.contains('unknown shorthand')) {
      final version = await _run(const ['--version']);
      final number = RegExp(
        r'gh version (\S+)',
      ).firstMatch(version?.stdout ?? '')?.group(1);
      return GhAccountsReading(
        const [],
        problem:
            'Listing gh accounts needs gh 2.81 or later'
            '${number == null ? '' : '; this one is $number'}.',
      );
    }
    final accounts = parseGhAuthStatus(result.stdout);
    if (accounts == null) {
      return GhAccountsReading(
        const [],
        problem: result.ok
            ? 'gh answered in a shape Karmashala does not read.'
            : 'gh auth status failed.',
      );
    }
    return GhAccountsReading(accounts);
  }
}

/// Parses `gh auth status --json hosts`. Any token in it is never kept.
List<GhAccount>? parseGhAuthStatus(String printed) {
  final Object? decoded;
  try {
    decoded = jsonDecode(printed.trim());
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['hosts'] is! Map) return null;
  final accounts = <GhAccount>[];
  for (final MapEntry(:key, :value) in (decoded['hosts'] as Map).entries) {
    if (value is! List) continue;
    final host = normalizeGithubHost('$key');
    if (host == null) continue;
    for (final entry in value) {
      if (entry is! Map) continue;
      final login = entry['login'];
      if (login is! String || login.isEmpty) continue;
      accounts.add(
        GhAccount(
          host: host,
          login: login,
          active: entry['active'] == true,
          ok: entry['state'] == 'success',
        ),
      );
    }
  }
  return accounts;
}
