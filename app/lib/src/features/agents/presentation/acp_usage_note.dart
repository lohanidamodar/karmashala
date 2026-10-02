/// What a card and a settings row say for an agent spoken to over ACP: the
/// protocol has no account or rate-limit call, so there is nothing to check.
/// What a running session reports of its own context and cost is on its
/// stats chip instead.
const String kAcpUsageLimitsNote = 'Usage limits are not reported over ACP';

/// The longer form, for a settings card with room for the reason.
const String kAcpUsageLimitsDetail =
    'The Agent Client Protocol has no account or rate-limit call, so there '
    'is nothing to read here. A running session shows the context and cost '
    'its agent reports on its stats chip.';
