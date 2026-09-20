import '../../util/describe_age.dart';
import './agent_installation.dart';

/// How long a version reading is worth trusting without asking again.
///
/// **A judgement, not a measurement, and it is deliberately one number in one
/// place.** It decides two things that must not drift apart: when the launch
/// check spends a process re-reading a version, and when a displayed version
/// admits it may be out of date. If the refresh bound were looser than the
/// display bound the app would call a number stale and decline to fix it; if it
/// were tighter it would refresh a number it was still presenting as current.
///
/// Twelve hours, because these CLIs ship several versions a day — Claude Code
/// went 2.1.245 → 2.1.263 in the time this row sat unrefreshed, and Codex
/// self-updated 0.145.0 → 0.153.4 *during a session*. A reading from this
/// morning is worth believing; one from yesterday is not. It is also what keeps
/// the launch check honest about cost: a machine relaunched five times in an
/// hour re-reads once, not five times.
///
/// It is not a setting. A cadence the user has to tune is a cadence nobody
/// tunes, and the age beside the number is what makes any choice here
/// survivable.
const Duration kVersionReadingFreshFor = Duration(hours: 12);

/// Whether a recorded version is worth presenting as the CLI's current one.
enum VersionFreshness {
  /// Read within [kVersionReadingFreshFor].
  fresh,

  /// Read, but long enough ago that the CLI may have updated itself since.
  stale,

  /// There is a number and no record of when it was read — every row written
  /// before the reading time was stored. Not treated as old *or* as current:
  /// nothing is known about its age, which is its own answer.
  undated,

  /// There is no version at all.
  unknown,
}

/// How much [installation]'s recorded version is worth as of [now].
VersionFreshness versionFreshness(
  AgentInstallation installation, {
  required DateTime now,
  Duration freshFor = kVersionReadingFreshFor,
}) {
  if (installation.version == null) return VersionFreshness.unknown;
  final readAt = installation.versionReadAt;
  if (readAt == null) return VersionFreshness.undated;
  final age = now.difference(readAt);
  return age.isNegative || age <= freshFor
      ? VersionFreshness.fresh
      : VersionFreshness.stale;
}

/// The version as a sentence that carries its own age, or null when there is no
/// version to describe.
///
/// **This is the half no cadence can replace.** A refresh rate decides how
/// often the number is right; the age decides whether the reader can tell. A
/// bare "2.1.252" beside a binary answering 2.1.263 is a confident false
/// statement of exactly the kind §19 exists to delete, and it stays one however
/// often it is refreshed — the reader has no way to know which reading they are
/// looking at. With an age attached, a stale number is merely old.
String? describeVersionReading(
  AgentInstallation installation, {
  required DateTime now,
  Duration freshFor = kVersionReadingFreshFor,
}) {
  final version = installation.version;
  if (version == null) return null;
  return switch (versionFreshness(installation, now: now, freshFor: freshFor)) {
    VersionFreshness.unknown => null,
    VersionFreshness.undated => '$version · read at an unknown time',
    VersionFreshness.fresh =>
      '$version · read '
          '${describeAge(now.difference(installation.versionReadAt!))}',
    // Says so, rather than letting the number speak for a binary that has had
    // half a day to replace itself.
    VersionFreshness.stale =>
      '$version · last read '
          '${describeAge(now.difference(installation.versionReadAt!))}, '
          'may be out of date',
  };
}
