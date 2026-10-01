import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:store_console/store_console.dart';

/// A store's logo where its name used to be written, the name in the tooltip
/// and for a screen reader (owner, 2026-10-01).
class StoreLogo extends StatelessWidget {
  const StoreLogo(this.store, {this.size = 16, this.color, super.key});

  final StoreKind store;
  final double size;

  /// The glyph's colour; the muted text colour when null.
  final Color? color;

  static IconData glyphOf(StoreKind store) => switch (store) {
    StoreKind.appStore => AppIcons.appStoreLogo,
    StoreKind.googlePlay => AppIcons.googlePlayLogo,
  };

  @override
  Widget build(BuildContext context) => Tooltip(
    message: store.label,
    waitDuration: const Duration(milliseconds: 400),
    child: Semantics(
      label: store.label,
      child: ExcludeSemantics(
        child: Icon(
          glyphOf(store),
          size: size,
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}
