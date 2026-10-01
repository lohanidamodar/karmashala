import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:store_console/store_console.dart';

/// A store's logo where its name used to be written, the name in the tooltip
/// and for a screen reader (owner, 2026-10-01). [StoreLogo.named] writes the
/// name beside it, where there is room: an app's detail.
class StoreLogo extends StatelessWidget {
  const StoreLogo(this.store, {this.size = 16, this.color, super.key})
    : style = null,
      named = false;

  /// The logo, then the store's name in [style].
  const StoreLogo.named(
    this.store, {
    this.size = 16,
    this.color,
    this.style,
    super.key,
  }) : named = true;

  final StoreKind store;
  final double size;

  /// Whether the name is written beside the logo.
  final bool named;

  /// The name's style, for [StoreLogo.named]; the ambient style when null.
  final TextStyle? style;

  /// The glyph's colour; the muted text colour when null.
  final Color? color;

  static IconData glyphOf(StoreKind store) => switch (store) {
    StoreKind.appStore => AppIcons.appStoreLogo,
    StoreKind.googlePlay => AppIcons.googlePlayLogo,
  };

  @override
  Widget build(BuildContext context) {
    if (!named) return _logo(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: _glyph(context)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            store.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }

  Widget _glyph(BuildContext context) => Icon(
    glyphOf(store),
    size: size,
    color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
  );

  Widget _logo(BuildContext context) => Tooltip(
    message: store.label,
    waitDuration: const Duration(milliseconds: 400),
    child: Semantics(
      label: store.label,
      child: ExcludeSemantics(child: _glyph(context)),
    ),
  );
}
