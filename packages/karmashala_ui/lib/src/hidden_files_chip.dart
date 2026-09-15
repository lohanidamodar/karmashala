/// The one control every browser offers for hidden entries.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'hidden_files.dart';

/// Shows or hides dot-files and anything Windows marks hidden. [hiddenCount] is
/// how many rows are being kept off screen, said out loud so a folder that
/// looks empty is never a mystery.
class HiddenFilesChip extends StatelessWidget {
  const HiddenFilesChip({required this.onChanged, this.hiddenCount = 0, super.key});

  final ValueChanged<bool> onChanged;
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    final shown = HiddenFilesPreference.shown;
    return Tooltip(
      // Only Windows has an attribute to name; elsewhere the dot is the rule.
      message: Platform.isWindows
          ? 'Dot-files, and anything Windows marks hidden'
          : 'Dot-files',
      child: FilterChip(
        label: Text(
          !shown && hiddenCount > 0 ? 'Hidden ($hiddenCount)' : 'Hidden',
        ),
        selected: shown,
        onSelected: (value) {
          HiddenFilesPreference.choose(value);
          onChanged(value);
        },
      ),
    );
  }
}

/// Folders first, then names, case-insensitively — the order every file
/// manager uses, and the one rule all three browsers now sort by.
int compareBrowsedRows({
  required bool aIsDirectory,
  required String aName,
  required bool bIsDirectory,
  required String bName,
}) {
  if (aIsDirectory != bIsDirectory) return aIsDirectory ? -1 : 1;
  return aName.toLowerCase().compareTo(bName.toLowerCase());
}
