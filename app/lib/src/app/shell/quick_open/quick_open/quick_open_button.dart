part of '../quick_open.dart';

// The title bar's quick open button and its key pill.

/// The mouse's way in to [QuickOpen] — a search field that is really a button.
/// It shipped with no mouse affordance at all, which most people never found.
///
/// Drawn as board A2's field: the raised tone (`s1`), a 6px corner, 26px
/// tall, the magnifier, a muted placeholder that says what it reaches, and
/// the chord in a key pill at the end. Its width is the title bar's to give.
class QuickOpenButton extends StatelessWidget {
  const QuickOpenButton({super.key});

  static const _placeholder = 'Jump to a session, project, file or command';

  /// The board's field: 10px in from each end, 8px between glyph and words.
  static const _padX = 10.0;

  /// The inner width, at 1x text, below which the key pill steps aside: the
  /// glyph, a few words of the placeholder and a "Ctrl Shift K"-long pill.
  static const _pillRoom = 150.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final muted = scheme.onSurfaceVariant;
    // The keymap's chord, not a literal: a remapped Ctrl+K should say so here.
    final chord = shellChordLabel<OpenQuickOpenIntent>(
      where: (intent) => intent.query.isEmpty,
    );
    return Tooltip(
      message: [_placeholder, ?chord].join('  ·  '),
      child: Material(
        color: tones.raised,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () => QuickOpen.show(context),
          child: Container(
            height: Chrome.control,
            padding: const EdgeInsets.symmetric(horizontal: _padX),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: tones.line),
            ),
            // The field's own width decides whether the pill fits; the title
            // bar sizes the field with a fixed width, never by intrinsics.
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  Icon(
                    AppIcons.magnifyingGlass,
                    size: Chrome.iconSmall,
                    color: muted,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      _placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: TypeSizes.field,
                        color: muted,
                      ),
                    ),
                  ),
                  // The chord is decoration — the tooltip says it too — so it
                  // is what the field gives up first, whole rather than cut.
                  if (chord != null &&
                      constraints.maxWidth >=
                          WidthClass.scaleBreakpoint(
                            _pillRoom,
                            MediaQuery.textScalerOf(context),
                          )) ...[
                    const SizedBox(width: Insets.sm),
                    _KeyPill(chord),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A chord as a key — board A2's `.kbd`: 11px dim ink in a 4px-cornered
/// outline on the floating hairline, written with spaces ("Ctrl K") the way a
/// keycap row reads rather than the `+` a menu writes.
class _KeyPill extends StatelessWidget {
  const _KeyPill(this.chord);

  final String chord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      decoration: BoxDecoration(
        border: Border.all(color: SurfaceTones.of(context).floatingLine),
        borderRadius: BorderRadius.circular(Insets.xs),
      ),
      child: Text(
        chord.replaceAll('+', ' '),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: TypeSizes.caption,
          height: 16 / 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
