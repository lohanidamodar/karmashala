import 'element_capture.dart';

/// One element a search matched, in the shape the page reports it.
///
/// The same descriptor is used for "what did I find" and "what did I click",
/// so a caller can list candidates and then act on one of them without a
/// second round trip through a different representation.
class FoundElement {
  const FoundElement({
    required this.tagName,
    required this.box,
    this.selector,
    this.elementId,
    this.classNames = const [],
    this.text = '',
    this.role,
    this.visible = true,
    this.interactive = false,
    this.inViewport = true,
    this.disabled = false,
    this.centerX,
    this.centerY,
  });

  /// A selector the page verified resolves back to this element, or null when
  /// none could be derived (shadow DOM). Null means the element can only be
  /// acted on by position.
  final String? selector;
  final String tagName;
  final String? elementId;
  final List<String> classNames;

  /// The element's visible label: its own text, or the `aria-label`,
  /// `placeholder`, `title` or `value` that stands in for one.
  final String text;

  /// `role`, explicit or implied, when the page could name one.
  final String? role;
  final bool visible;

  /// Whether this is something a user can act on — a link, a button, a field,
  /// or anything carrying an interactive role.
  final bool interactive;

  /// Whether the element's centre is currently inside the viewport.
  final bool inViewport;
  final bool disabled;

  /// Viewport coordinates of the element's centre at the time of the search.
  final double? centerX;
  final double? centerY;

  /// The element's rectangle in page coordinates.
  final ElementBox box;

  /// A short human label, e.g. `button#submit.primary`.
  String get description {
    final buffer = StringBuffer(tagName);
    if (elementId != null && elementId!.isNotEmpty) buffer.write('#$elementId');
    for (final className in classNames.take(2)) {
      buffer.write('.$className');
    }
    return buffer.toString();
  }

  static FoundElement fromJson(Map<String, Object?> json) => FoundElement(
    selector: json['selector'] as String?,
    tagName: json['tagName']?.toString() ?? 'unknown',
    elementId: json['id'] as String?,
    classNames: [
      for (final name in (json['classNames'] as List? ?? const []))
        name.toString(),
    ],
    text: json['text']?.toString() ?? '',
    role: json['role'] as String?,
    visible: json['visible'] != false,
    interactive: json['interactive'] == true,
    inViewport: json['inViewport'] != false,
    disabled: json['disabled'] == true,
    centerX: (json['centerX'] as num?)?.toDouble(),
    centerY: (json['centerY'] as num?)?.toDouble(),
    box: ElementBox.fromJson(
      (json['box'] as Map<String, Object?>?) ?? const {},
    ),
  );

  /// One line for a listing an agent reads.
  String toListing() {
    final parts = <String>[
      description,
      if (text.isNotEmpty) '"${_squash(text)}"',
      if (selector != null) '`$selector`' else '(no selector)',
      box.toString(),
    ];
    final flags = <String>[
      if (interactive) 'interactive',
      if (!visible) 'hidden',
      if (!inViewport) 'off-screen',
      if (disabled) 'disabled',
    ];
    return '${parts.join('  ')}${flags.isEmpty ? '' : '  [${flags.join(', ')}]'}';
  }

  static String _squash(String value, {int max = 80}) {
    final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}

/// What a click actually did.
class ClickResult {
  const ClickResult({
    required this.element,
    required this.x,
    required this.y,
    required this.candidates,
  });

  /// The element the click landed on, as the page described it at click time.
  final FoundElement element;

  /// Viewport coordinates the synthetic mouse events were dispatched at.
  final double x;
  final double y;

  /// How many elements the query matched; > 1 means an index was used.
  final int candidates;
}

/// The outcome of typing or filling: what the field holds afterwards.
class TypeResult {
  const TypeResult({
    required this.element,
    required this.text,
    required this.value,
    this.submitted = false,
  });

  /// The field acted on, or null when typing went to whatever had focus.
  final FoundElement? element;

  /// The text that was sent.
  final String text;

  /// The field's value read back afterwards, or null when it could not be
  /// read (a contenteditable, or no element was targeted).
  final String? value;

  /// Whether Enter was pressed afterwards.
  final bool submitted;

  /// Whether the field ended up holding exactly what was sent.
  bool get matches => value == null || value == text;
}
