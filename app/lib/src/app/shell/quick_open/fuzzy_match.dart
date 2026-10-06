/// Fuzzy matching and scoring for quick open: the shared search rule, with
/// scattered initials allowed. What *kind* of thing is being scored belongs to
/// the caller, as a per-item weight.
library;

import 'package:karmashala_core/util.dart';

/// What a query matched in one piece of text.
typedef FuzzyMatch = SearchMatch;

/// Scores [query] against [text], or null when it does not match. A found word
/// always beats a scattered subsequence.
FuzzyMatch? fuzzyMatch(String query, String text) =>
    searchMatch(query, text, initials: true);
