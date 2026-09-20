import 'package:meta/meta.dart';

/// The variables that make Claude Code authenticate as something other than the
/// interactive `/login`, in the order its own precedence puts them.
///
/// Read off the Claude Code documentation on 2026-09-20
/// (`code.claude.com/docs/en/authentication`), not assumed: only the first two
/// are pay-per-token. `CLAUDE_CODE_OAUTH_TOKEN` is a *subscription* token from
/// `claude setup-token`, so a stale one misbills nobody — it merely outranks
/// the live login and runs the pane as whichever account minted it.
const Set<String> anthropicCredentialVariables = {
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN',
};

/// The subset of [anthropicCredentialVariables] that bills per token.
const Set<String> anthropicBillingVariables = {
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
};

/// Variables whose presence means the user pointed Claude Code at a provider of
/// their own — Bedrock, Vertex, Foundry, a gateway — where the credentials
/// beside them are the ones that have to reach the child.
///
/// Documented names as of 2026-09-20. `CLAUDE_CODE_SKIP_BEDROCK_AUTH` and
/// `CLAUDE_CODE_SKIP_VERTEX_AUTH` are deliberately **absent**: the current docs
/// carry no such variable, only `CLAUDE_CODE_SKIP_MANTLE_AUTH`.
const Set<String> anthropicProviderOverrideVariables = {
  'CLAUDE_CODE_USE_BEDROCK',
  'CLAUDE_CODE_USE_VERTEX',
  'CLAUDE_CODE_USE_FOUNDRY',
  'CLAUDE_CODE_USE_AWS',
  'CLAUDE_CODE_USE_MANTLE',
  'CLAUDE_CODE_SKIP_MANTLE_AUTH',
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_BEDROCK_BASE_URL',
  'ANTHROPIC_BEDROCK_MANTLE_BASE_URL',
  'ANTHROPIC_VERTEX_BASE_URL',
  'ANTHROPIC_FOUNDRY_BASE_URL',
  'ANTHROPIC_FOUNDRY_RESOURCE',
  'ANTHROPIC_FOUNDRY_API_KEY',
  'ANTHROPIC_FOUNDRY_AUTH_TOKEN',
  'ANTHROPIC_AWS_API_KEY',
  'ANTHROPIC_PROFILE',
  // Not a provider: it moves `.credentials.json` somewhere we did not look, so
  // "no login found" stops being evidence and we must not act on it.
  'CLAUDE_CONFIG_DIR',
};

/// What a launch decided about the credential variables it inherited.
@immutable
class InheritedCredentialDecision {
  const InheritedCredentialDecision({
    this.inherited = const {},
    this.removed = const {},
    this.keptForOverride,
    this.keptBySetting = const {},
    this.keptWithoutLogin = false,
  });

  /// Nothing was inherited, so nothing was decided.
  static const none = InheritedCredentialDecision();

  /// The credential variables found in the host environment, by name only.
  final Set<String> inherited;

  /// The names deleted from the child's environment.
  final Set<String> removed;

  /// The override variable that made the inherited credentials deliberate.
  final String? keptForOverride;

  /// Names a Karmashala setting supplies, so the child's value is ours and the
  /// settings page is not made to lie about it.
  final Set<String> keptBySetting;

  /// Whether the credentials were left because no usable CLI login was found.
  final bool keptWithoutLogin;

  bool get changedEnvironment => removed.isNotEmpty;

  /// Whether anything removed would have billed per token.
  bool get removedBilling => removed.any(anthropicBillingVariables.contains);

  /// One line for the launch log — **names only**, never a value or its length.
  String get logSummary {
    if (inherited.isEmpty) return 'none';
    final names = _ordered(inherited).join(',');
    if (removed.isNotEmpty) return 'stripped($names)';
    if (keptForOverride != null) return 'kept($names, override=$keptForOverride)';
    if (keptBySetting.isNotEmpty) {
      return 'kept($names, set by Karmashala)';
    }
    return 'kept($names, no CLI login)';
  }
}

/// Decides which inherited Anthropic credential variables a Claude Code pane
/// must not be given.
///
/// [hostEnvironment] is the environment the child would inherit; [settingsEnvironment]
/// is Karmashala's own overlay, which always wins so Settings never describes a
/// child that got something else. Pure: nothing here reads a file, and no value
/// is ever returned, logged or compared — only names.
InheritedCredentialDecision decideInheritedCredentials({
  required Map<String, String> hostEnvironment,
  Map<String, String> settingsEnvironment = const {},
  required bool hasUsableLogin,
}) {
  final inherited = {
    for (final name in anthropicCredentialVariables)
      if (_isSet(hostEnvironment[name])) name,
  };
  if (inherited.isEmpty) return InheritedCredentialDecision.none;

  // Ours beats the shell's, and is never removed: the child really does get
  // what the settings page shows.
  final bySetting = {
    for (final name in inherited)
      if (settingsEnvironment.containsKey(name)) name,
  };

  final override = _overrideIn(hostEnvironment) ?? _overrideIn(settingsEnvironment);
  if (override != null) {
    return InheritedCredentialDecision(
      inherited: inherited,
      keptForOverride: override,
      keptBySetting: bySetting,
    );
  }
  // No login to fall back on: removing the key would leave the pane unable to
  // authenticate at all, which is a worse answer than the wrong bill.
  if (!hasUsableLogin) {
    return InheritedCredentialDecision(
      inherited: inherited,
      keptBySetting: bySetting,
      keptWithoutLogin: true,
    );
  }
  return InheritedCredentialDecision(
    inherited: inherited,
    removed: {
      for (final name in inherited)
        if (!bySetting.contains(name)) name,
    },
    keptBySetting: bySetting,
  );
}

/// What the session bar says when a launch changed the environment. Names the
/// variables and the reason; a value never reaches a sentence.
String inheritedCredentialNotice(InheritedCredentialDecision decision) {
  final names = _ordered(decision.removed).join(' and ');
  final plural = decision.removed.length > 1;
  final consequence = decision.removedBilling
      ? 'this pane would have billed the pay-per-token API instead of the '
            'signed-in account'
      : 'this pane would have run as whichever account minted it, not the '
            'signed-in one';
  return 'Claude Code is signed in here, so Karmashala left '
      '$names out of this pane: ${plural ? 'they were' : 'it was'} set in your '
      'shell and $consequence.';
}

/// An empty value is not a credential, and Windows keeps empty variables about.
bool _isSet(String? value) => value != null && value.trim().isNotEmpty;

/// Booleans arrive as `0`/`false` when someone turned a provider *off*; that is
/// not a deliberate provider, so it must not buy an exemption.
String? _overrideIn(Map<String, String> environment) {
  for (final name in _ordered(anthropicProviderOverrideVariables)) {
    final value = environment[name];
    if (!_isSet(value)) continue;
    final normalized = value!.trim().toLowerCase();
    if (normalized == '0' || normalized == 'false') continue;
    return name;
  }
  return null;
}

List<String> _ordered(Set<String> names) => names.toList()..sort();
