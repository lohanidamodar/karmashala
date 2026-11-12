/// The consent tier for the browser tools. Exactly one capability is gated:
/// clicking and typing are bounded by what is on the screen, while
/// `browser_evaluate` is unbounded code in an already-authenticated origin — so
/// the split is not "reads free, writes gated", which would put the most
/// dangerous tool on the safe side. One grant per project, because a prompt per
/// call is a prompt nobody reads.
library;

import 'dart:convert';

/// Where a person grants a browser capability, as refusals and tool
/// descriptions name it. Kept in step with the app's settings catalogue.
const kBrowserConsentLocation = 'Settings → Permissions → Browser';

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

  /// How the grant was made. Recorded because a permission with no provenance
  /// is indistinguishable from a default.
  final String grantedBy;

  Map<String, Object?> toJson() => <String, Object?>{
    'scope': scopeId,
    'capability': capability.token,
    'grantedAt': grantedAt.toUtc().toIso8601String(),
    'grantedBy': grantedBy,
  };

  /// Null for a row this build cannot read. Dropped rather than guessed at: the
  /// failure mode of guessing is granting a permission nobody gave.
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

/// Where grants are read from and written to. An interface so the store is
/// testable without a database, and so this feature need not know the table.
abstract interface class ConsentJournal {
  String? read(String key);
  void write(String key, String value);
}

/// An in-memory journal, for tests and any container with no database.
class MemoryConsentJournal implements ConsentJournal {
  final Map<String, String> _values = <String, String>{};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;
}

class BrowserConsentStore {
  BrowserConsentStore(this._journal);

  final ConsentJournal _journal;

  /// Versioned so a shape change is a new key rather than a silent misread —
  /// which for a permission record means losing a grant or inventing one.
  static const String storageKey = 'browser.consent.v1';

  List<BrowserConsentGrant> all() {
    final raw = _journal.read(storageKey);
    if (raw == null) return const <BrowserConsentGrant>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Corrupt storage reads as "nothing was granted": a lost grant costs one
      // click, a phantom grant costs arbitrary code in a logged-in browser.
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
  /// second row, so `all()` stays one row per (scope, capability).
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

  void revoke(String scopeId, BrowserCapability capability) =>
      _save(<BrowserConsentGrant>[
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
  const BrowserConsentDecision.allowed() : allowed = true, reason = '';
  const BrowserConsentDecision.denied(this.reason) : allowed = false;

  final bool allowed;

  /// The whole refusal message, written for an agent that has to explain it to
  /// a person and then wait. Empty when [allowed].
  final String reason;
}

/// What [BrowserTools] asks before running a gated tool. An interface, not the
/// store, because the caller must also resolve which project the call is in.
abstract interface class BrowserConsent {
  BrowserConsentDecision check(BrowserCapability capability);
}

/// The default when nothing wired a consent source in: refuses everything. A
/// `BrowserTools` built without consent must not be the permissive one.
class DeniedBrowserConsent implements BrowserConsent {
  const DeniedBrowserConsent();

  @override
  BrowserConsentDecision check(BrowserCapability capability) =>
      BrowserConsentDecision.denied(
        'Karmashala cannot tell which project this call belongs to, so it '
        'cannot check whether "${capability.token}" was granted for it. Ask '
        'the developer to select a checkout in Karmashala (or run this from a '
        'session that has one) and to grant it under '
        '$kBrowserConsentLocation.',
      );
}
