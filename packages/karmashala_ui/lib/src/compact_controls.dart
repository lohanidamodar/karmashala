import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// The house picker for a few exclusive choices: no tick on the chosen
/// segment, compact under a pointer and the 48dp target under a thumb.
class CompactSegmented<T> extends StatelessWidget {
  const CompactSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.tight = false,
    super.key,
  });

  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Less padding beside each label, for long names that share a phone's
  /// row with a way back; the targets keep their height.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    return SegmentedButton<T>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: density.controlDensity,
        tapTargetSize: density.tapTargetSize,
        padding: tight
            ? const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: Insets.xs),
              )
            : null,
      ),
      segments: segments,
      selected: {selected},
      onSelectionChanged: (picked) => onChanged(picked.single),
    );
  }
}

/// **The one filter control**: a funnel, filled with a count badge while any
/// filter is set, opening the filters wherever [onPressed] puts them.
class FilterFunnelButton extends StatelessWidget {
  const FilterFunnelButton({
    required this.count,
    required this.onPressed,
    super.key,
  });

  /// How many filters are set.
  final int count;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = Icon(count > 0 ? AppIcons.funnelFill : AppIcons.funnel);
    return IconButton(
      tooltip: count == 0 ? 'Filters' : 'Filters ($count set)',
      icon: count == 0
          ? icon
          : Badge.count(
              count: count,
              // A setting, not an alarm: the accent, never the error red.
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
              child: icon,
            ),
      onPressed: onPressed,
    );
  }
}

/// A search box's look everywhere: dense, with the magnifier in front.
InputDecoration compactSearchDecoration({required String hintText}) =>
    InputDecoration(
      isDense: true,
      hintText: hintText,
      prefixIcon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
      prefixIconConstraints: const BoxConstraints(minWidth: Chrome.tabStrip),
    );
