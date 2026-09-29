/// What this server announces in `welcome.features`, the one place a client
/// learns what it serves beyond the protocol number (spec §3.2 rule 3).
///
/// Additive and named: a feature is added here in the same commit that serves
/// it, and never removed while a deployed client may still ask for it.
const Set<String> kServerFeatures = <String>{};
