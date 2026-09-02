/// The consent tier for the browser tools: which of them a person has to say
/// yes to once, and where that yes is written down.
///
/// ## Where the line is drawn, and why it is drawn there
///
/// Every browser tool acts on a real Chrome holding the developer's real
/// logins, so "it can touch a logged-in session" is true of all twelve and
/// therefore useless as a rule. The line that actually separates them is
/// **whether the worst case is bounded by what is on the screen**:
///
/// * `browser_click`, `browser_type`, `browser_fill`, `browser_key` act at
///   human granularity on visible affordances, in a window the developer is
///   looking at, with the browser pane mirroring it. The worst a click can do
///   is what a button on that page does. That is a bounded, observable risk,
///   and gating it would mean a consent prompt for every step of every flow —
///   which trains a person to click "allow" without reading, and buys nothing.
/// * `browser_evaluate` is unbounded. It is a general-purpose code execution
///   primitive pointed at an origin that is already authenticated: one call can
///   read `document.cookie` and every token in `localStorage`, POST them
///   somewhere, and print `null`. Nothing about that is visible in the pane,
///   and no annotation on the tool constrains it.
///
/// So exactly one capability is gated. Not "reads are free and writes are
/// gated" — that split sounds principled and puts the single most dangerous
/// tool in this app on the safe side of the line, because `evaluate` reads.
///
/// ## Why cookies are not a second capability
///
/// The brief for this work named cookie access as the other thing worth
/// gating, and it is right. It is not a second enum value because this app's
/// CDP client has no cookie surface at all: there is no `Network.getCookies`
/// call anywhere under `features/browser`, and no `browser_cookies` tool. The
/// only route from an agent to a session cookie today is `document.cookie`
/// inside [BrowserCapability.evaluate] — so gating evaluate *is* gating cookie
/// reads, and inventing an unused enum value would be a policy about a tool
/// that does not exist. If a cookie tool is ever added, it gets its own value
/// here and the same one-time grant.
///
/// ## Why one grant per project, and not per call
///
/// A prompt per call is a prompt nobody reads. A grant per project is a
/// decision someone makes once, with the project named, that stays visible in
/// Settings → Tools and can be taken back. It is scoped to a project rather
/// than to a session because sessions are made and ended constantly — a
/// per-session grant is a per-call prompt with extra steps — and rather than
/// globally because "I trust the agent working on this app" is a much smaller
/// claim than "I trust every agent this app will ever run".
library;

import 'dart:convert';

/// A thing a browser tool has to be permitted to do.
enum BrowserCapability {
  /// Running caller-supplied JavaScript in the attached page
  /// (`browser_evaluate`). Includes, by construction, reading cookies,
  /// `localStorage`, and anything else the page's origin can reach.
  evaluate('evaluate');

  const BrowserCapability(this.token);

  /// The stable persisted name. Not `name`, so renaming the Dart identifier
  /// cannot silently revoke everyone's grants.
  final String token;

  static BrowserCapability? byToken(String token) {
    for (final capability in values) {
      if (capability.token == token) return capability;
    }
    return null;
  }
}

/// One recorded yes.
class BrowserConsentGrant {
  const BrowserConsentGrant({
    required this.scopeId,
    required this.capability,
    required this.grantedAt,
    required this.grantedBy,
  });

  /// The project id this grant covers.
  final String scopeId;
  final BrowserCapability capability;
  final DateTime grantedAt;

  /// How the grant was made — today always the settings screen. Recorded
  /// because a permission with no provenance is indistinguishable from a
  /// default, and the whole point of a grant is that somebody chose it.
  final String grantedBy;

  Map<String, Object?> toJson() => <String, Object?>{
    'scope': scopeId,
    'capability': capability.token,
    'grantedAt': grantedAt.toUtc().toIso8601String(),
    'grantedBy': grantedBy,
  };

  /// Null for a row this build cannot read — an unknown capability token, a
  /// missing scope, an unparseable date. A grant that cannot be read is
  /// dropped rather than guessed at: the failure mode of guessing is granting
  /// a permission nobody gave.
  static BrowserConsentGrant? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final scope = raw['scope'];
    final capability = raw['capability'];
    if (scope is! String || scope.isEmpty || capability is! String) return null;
    final parsed = BrowserCapability.byToken(capability);
    if (parsed == null) return null;
    final at = DateTime.tryParse('${raw['grantedAt']}');
    if (at == null) return null;
    return BrowserConsentGrant(
      scopeId: scope,
      capability: parsed,
      grantedAt: at,
      grantedBy: raw['grantedBy'] is String
          ? raw['grantedBy']! as String
          : 'not recorded',
    );
  }
}

/// Where grants are read from and written to.
///
/// An interface rather than a direct [AppDatabase] dependency so the store is
/// testable without a database, and so `features/browser` does not have to know
/// which table this lands in.
abstract interface class ConsentJournal {
  String? read(String key);
  void write(String key, String value);
}

/// An in-memory journal. Used by tests, and by any container with no database
/// behind it.
class MemoryConsentJournal implements ConsentJournal {
  final Map<String, String> _values = <String, String>{};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;
}

/// The recorded grants, and the two verbs that change them.
class BrowserConsentStore {
  BrowserConsentStore(this._journal);

  final ConsentJournal _journal;

  /// Versioned so a future shape change is a new key rather than a silent
  /// misread of the old one — which, for a permission record, would mean
  /// either losing a grant or inventing one.
  static const String storageKey = 'browser.consent.v1';

  List<BrowserConsentGrant> all() {
    final raw = _journal.read(storageKey);
    if (raw == null) return const <BrowserConsentGrant>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Corrupt storage reads as "nothing was granted". Fail closed: the cost
      // of a lost grant is one click in Settings, the cost of a phantom grant
      // is arbitrary code in a logged-in browser.
      return const <BrowserConsentGrant>[];
    }
    if (decoded is! Map || decoded['grants'] is! List) {
      return const <BrowserConsentGrant>[];
    }
    return <BrowserConsentGrant>[
      for (final row in decoded['grants']! as List)
        ?BrowserConsentGrant.fromJson(row),
    ];
  }

  /// The grant covering [capability] in [scopeId], or null if there is none.
  BrowserConsentGrant? grantFor(String scopeId, BrowserCapability capability) {
    for (final grant in all()) {
      if (grant.scopeId == scopeId && grant.capability == capability) {
        return grant;
      }
    }
    return null;
  }

  bool isGranted(String scopeId, BrowserCapability capability) =>
      grantFor(scopeId, capability) != null;

  /// Records a yes. Re-granting refreshes the timestamp rather than adding a
  /// second row, so `all()` stays one row per (scope, capability) and the
  /// settings list cannot grow duplicates.
  void grant(
    String scopeId,
    BrowserCapability capability, {
    required String grantedBy,
    DateTime? at,
  }) {
    final kept = <BrowserConsentGrant>[
      for (final grant in all())
        if (grant.scopeId != scopeId || grant.capability != capability) grant,
      BrowserConsentGrant(
        scopeId: scopeId,
        capability: capability,
        grantedAt: at ?? DateTime.now().toUtc(),
        grantedBy: grantedBy,
      ),
    ];
    _save(kept);
  }

  void revoke(String scopeId, BrowserCapability capability) => _save(<
    BrowserConsentGrant
  >[
    for (final grant in all())
      if (grant.scopeId != scopeId || grant.capability != capability) grant,
  ]);

  void _save(List<BrowserConsentGrant> grants) => _journal.write(
    storageKey,
    jsonEncode(<String, Object?>{
      'grants': <Object?>[for (final grant in grants) grant.toJson()],
    }),
  );
}

/// The answer to "may this call proceed", and if not, what to tell the agent.
class BrowserConsentDecision {
  const BrowserConsentDecision.allowed()
    : allowed = true,
      reason = '';
  const BrowserConsentDecision.denied(this.reason) : allowed = false;

  final bool allowed;

  /// The whole refusal message, written for an agent that has to explain it to
  /// a person and then wait. Empty when [allowed].
  final String reason;
}

/// What [BrowserTools] asks before running a gated tool.
///
/// An interface, not the store, because the caller also has to resolve *which*
/// project the call belongs to — and that answer lives in the session and
/// repository tables, which `features/browser` has no business reading.
abstract interface class BrowserConsent {
  BrowserConsentDecision check(BrowserCapability capability);
}

/// The default when nothing wired a consent source in.
///
/// Refuses everything. A `BrowserTools` built without consent — a test, a
/// future embedding, a code path someone forgets to thread the container
/// through — must not be the permissive one; the same fail-closed reasoning
/// the control server already applies to its own auth.
class DeniedBrowserConsent implements BrowserConsent {
  const DeniedBrowserConsent();

  @override
  BrowserConsentDecision check(BrowserCapability capability) =>
      BrowserConsentDecision.denied(
        'Karmashala cannot tell which project this call belongs to, so it '
        'cannot check whether "${capability.token}" was granted for it. Ask '
        'the developer to select a checkout in Karmashala (or run this from a '
        'session that has one) and to grant it under Settings → Tools → '
        'Browser.',
      );
}
