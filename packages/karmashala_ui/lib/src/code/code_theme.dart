import 'package:flutter/material.dart' show Brightness, TextStyle;
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';

/// The Atom One map for [brightness] — the same two themes the transcript
/// uses. Each is a `const` map, so its identity is stable and the controller's
/// memo can compare palettes by reference.
Map<String, TextStyle> codeHighlightTheme(Brightness brightness) =>
    brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;
