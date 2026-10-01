import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show StoreAppIcon;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/store_icons.dart';

/// An app's icon as a rounded square, or — when the store has none to give
/// (unpublished, a draft, not looked up yet) or it cannot be brought here —
/// a neutral square with the name's first letter. Decorative: the name is
/// always beside it.
class StoreAppIconView extends ConsumerWidget {
  const StoreAppIconView({
    required this.icon,
    required this.name,
    required this.size,
    super.key,
  });

  final StoreAppIcon? icon;
  final String name;
  final double size;

  /// The list's size and the detail's, by density.
  static double listSize(BuildContext context) =>
      UiDensity.of(context).isTouch ? 40 : 32;
  static double detailSize(BuildContext context) =>
      UiDensity.of(context).isTouch ? 56 : 48;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = icon?.path;
    final bytes = path == null
        ? null
        : ref
              .watch(
                storeIconBytesProvider((
                  path: path,
                  checkedAt: icon!.checkedAt,
                )),
              )
              .value;
    final radius = BorderRadius.circular(size * 0.22);
    final placeholder = _Placeholder(name: name, size: size, radius: radius);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: bytes == null
            ? placeholder
            : ClipRRect(
                borderRadius: radius,
                child: Image.memory(
                  bytes,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  errorBuilder: (_, _, _) => placeholder,
                ),
              ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.name,
    required this.size,
    required this.radius,
  });

  final String name;
  final double size;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trimmed = name.trim();
    final letter = trimmed.isEmpty
        ? null
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: radius,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Center(
        child: letter == null
            ? Icon(
                AppIcons.package,
                size: size * 0.5,
                color: scheme.onSurfaceVariant,
              )
            : Text(
                letter,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: size * 0.45,
                  height: 1,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
