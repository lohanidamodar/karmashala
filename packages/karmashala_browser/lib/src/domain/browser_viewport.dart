/// A viewport a page can be emulated at. The names are the project's width
/// classes — compact < 600, medium 600–839, expanded ≥ 840 — and each default
/// is a representative width inside its class.
class BrowserViewport {
  const BrowserViewport({
    required this.name,
    required this.width,
    required this.height,
    this.mobile = false,
  });

  /// A phone held upright (390 × 844).
  static const compact = BrowserViewport(
    name: 'compact',
    width: 390,
    height: 844,
    mobile: true,
  );

  /// A tablet held upright (768 × 1024).
  static const medium = BrowserViewport(
    name: 'medium',
    width: 768,
    height: 1024,
    mobile: true,
  );

  /// A laptop window (1280 × 800).
  static const expanded = BrowserViewport(name: 'expanded', width: 1280, height: 800);

  static const List<BrowserViewport> widthClasses = [compact, medium, expanded];

  final String name;
  final int width;
  final int height;

  /// Emulates a touch-sized mobile viewport: meta viewport honoured, overlay
  /// scrollbars.
  final bool mobile;

  /// The width class [width] falls in.
  static String widthClassOf(int width) => width < 600
      ? 'compact'
      : width < 840
      ? 'medium'
      : 'expanded';

  /// A width class by name, or a custom width (`"1024"` or `"1024x768"`).
  static BrowserViewport? parse(String value) {
    final named = widthClasses.where((v) => v.name == value.trim()).firstOrNull;
    if (named != null) return named;
    final match = RegExp(r'^\s*(\d{3,4})(?:\s*[xX×]\s*(\d{3,4}))?\s*$')
        .firstMatch(value);
    if (match == null) return null;
    final width = int.parse(match[1]!);
    if (width < 200 || width > 3840) return null;
    final height = int.tryParse(match[2] ?? '') ?? (width < 600 ? 844 : 900);
    return BrowserViewport(
      name: '${width}x$height',
      width: width,
      height: height,
      mobile: width < 600,
    );
  }

  @override
  String toString() => '$name ($width×$height${mobile ? ', mobile' : ''})';
}
