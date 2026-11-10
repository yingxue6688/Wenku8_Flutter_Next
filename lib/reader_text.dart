import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'epub_rich_layout.dart';
import 'local_book_media.dart';
import 'local_image_layout.dart';
import 'reader_rich_content.dart';
import 'reader_tap_surface.dart';

// A fixed inline box is not discarded as leading whitespace by SkParagraph's
// justification. One placeholder code unit maps back to zero source characters.
const readerIndentLength = 1;
const readerIndentPlaceholder = '\ufffc';

TextSpan readerParagraphSpan({
  required List<InlineSpan> children,
  required TextStyle style,
  required bool indent,
  double indentEm = 2.0,
  double? continuationWidth,
}) => TextSpan(
  style: style,
  children: [
    if (indent && indentEm > 0)
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: ExcludeSemantics(
          // Text.rich scales inline widgets with its TextScaler already.
          child: SizedBox(width: (style.fontSize ?? 19) * indentEm, height: 0),
        ),
      ),
    ...children,
    if (continuationWidth != null)
      WidgetSpan(
        child: ExcludeSemantics(
          child: SelectionContainer.disabled(
            // A geometry-only next line keeps a page break a soft wrap. It
            // contributes no selectable text and is clipped by the fragment.
            child: SizedBox(width: continuationWidth, height: 0),
          ),
        ),
      ),
  ],
);

List<PlaceholderDimensions> readerIndentDimensions(
  bool indent,
  double font, {
  double indentEm = 2.0,
}) => [
  if (indent && indentEm > 0)
    PlaceholderDimensions(
      size: Size(font * indentEm, 0),
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      baselineOffset: 0,
    ),
];

/// Resolves the effective [TextStyle] for an EPUB block by combining the
/// user's baseline reader typography with the block's relative scale, weight,
/// embedded font tiering, and theme-adapted color.
TextStyle resolveEpubBlockTextStyle({
  required TextStyle baseStyle,
  EpubBlockStyle? blockStyle,
  int? bookId,
  EpubChapterLayout? epubLayout,
  bool userSelectedCustomFont = false,
  Color? paperColor,
  Color? onPaperColor,
}) {
  final embeddedFonts = epubLayout?.embeddedFonts ?? const <String, String>{};
  var resolved = baseStyle;
  final baseFontSize = baseStyle.fontSize ?? 19.0;

  // Smart font tiering:
  // - Blocks with an explicit CSS `font-family` (headings, metadata, styled
  //   paragraphs, quotes, callouts) always honor that explicit family and its
  //   CJK fallback stack (e.g. Duokan `DK-KAITI`, `DK-HEITI`).
  // - Ordinary body paragraphs use the EPUB body font only when the user has
  //   not explicitly selected a custom reader font.
  final hasExplicitBlockFont = blockStyle?.fontFamily != null;
  final candidateFamily =
      blockStyle?.fontFamily ??
      (!userSelectedCustomFont ? epubLayout?.bodyFontFamily : null);
  if (candidateFamily != null &&
      (hasExplicitBlockFont || !userSelectedCustomFont)) {
    final loadedFamily = EpubFontManager.resolveFontFamily(
      bookId,
      candidateFamily,
      embeddedFonts,
    );
    final fallbacks = EpubFontManager.fontFamilyFallbacksFor(candidateFamily);
    resolved = resolved.copyWith(
      fontFamily: loadedFamily ?? candidateFamily,
      fontFamilyFallback: fallbacks ?? resolved.fontFamilyFallback,
    );
  }

  if (blockStyle == null) return resolved;

  final scale = blockStyle.effectiveScale;
  final fontSize = baseFontSize * scale;
  FontWeight? weight = resolved.fontWeight;
  if (blockStyle.fontWeight != null) {
    final index = ((blockStyle.fontWeight! ~/ 100) - 1).clamp(0, 8);
    weight = FontWeight.values[index];
  } else if (blockStyle.isHeading) {
    weight = FontWeight.w700;
  }

  FontStyle? fontStyle = resolved.fontStyle;
  if (blockStyle.italic == true) {
    fontStyle = FontStyle.italic;
  }

  Color? textColor = resolved.color;
  final effectivePaper = paperColor ?? const Color(0xFFFDFBF7);
  final effectiveOnPaper =
      onPaperColor ?? resolved.color ?? const Color(0xFF1F1D1A);
  if (blockStyle.textColor != null) {
    textColor = EpubColorAdapter.adaptTextColor(
      Color(blockStyle.textColor!),
      paperColor: effectivePaper,
      defaultTextColor: effectiveOnPaper,
      backgroundColor: blockStyle.backgroundColor != null
          ? Color(blockStyle.backgroundColor!)
          : null,
    );
  } else if (blockStyle.kind == EpubBlockKind.figcaption &&
      blockStyle.fontFamily == null) {
    textColor = effectiveOnPaper.withValues(alpha: 0.74);
  } else if (blockStyle.kind == EpubBlockKind.blockquote) {
    textColor = effectiveOnPaper.withValues(alpha: 0.88);
  }

  double? height = resolved.height;
  if (blockStyle.isHeading) {
    height =
        blockStyle.lineHeight?.clamp(1.12, 2.6) ??
        math.min(resolved.height ?? 1.72, 1.38);
  } else if (blockStyle.kind == EpubBlockKind.paragraph &&
      blockStyle.fontScale != null &&
      blockStyle.textIndentEm == 0 &&
      blockStyle.lineHeight != null) {
    // Keep compact publisher text at its authored minimum leading, so low
    // body line-spacing settings do not crowd front matter or split titles.
    // Larger reader settings can still expand this leading.
    height =
        1 +
        (blockStyle.lineHeight!.clamp(1.05, 2.6) - 1) *
            (math.max(resolved.height ?? 1.72, 1.72) - 1) /
            0.72;
  } else if (blockStyle.kind != EpubBlockKind.paragraph &&
      blockStyle.lineHeight != null) {
    height = blockStyle.lineHeight!.clamp(1.12, 2.6);
  }

  double? letterSpacing = resolved.letterSpacing;
  if (blockStyle.letterSpacingEm != null) {
    letterSpacing = blockStyle.letterSpacingEm! * fontSize;
  }

  return resolved.copyWith(
    fontSize: fontSize,
    fontWeight: weight,
    fontStyle: fontStyle,
    color: textColor,
    height: height,
    letterSpacing: letterSpacing,
    fontFamily: blockStyle.kind == EpubBlockKind.pre
        ? 'monospace'
        : resolved.fontFamily,
  );
}

/// Images and publisher layouts have structural gaps. A user paragraph-gap
/// override applies to prose, not to lines split from one heading or paragraph.
double readerEpubGapBefore({
  required ReaderRichParagraph format,
  required ReaderRichParagraph? previous,
  EpubBlockStyle? blockStyle,
  EpubBlockStyle? previousBlockStyle,
  bool image = false,
  bool previousImage = false,
  required double font,
  required double lineHeight,
  required double width,
  required double defaultGap,
  required bool overrideGap,
}) {
  bool publisherLayout(EpubBlockStyle? block) =>
      block != null &&
      (block.isHeading ||
          block.kind != EpubBlockKind.paragraph ||
          block.hasBoxDecoration ||
          block.fontScale != null && block.textIndentEm == 0);
  final continuation = blockStyle?.lineBreakBefore == true;
  final imageBoundary = image || previousImage;
  return format.gapBefore(
    continuation ? null : previous,
    font: font,
    lineHeight: lineHeight,
    width: width,
    defaultGap: continuation || imageBoundary ? 0 : defaultGap,
    overrideGap:
        overrideGap &&
        !continuation &&
        !imageBoundary &&
        !publisherLayout(blockStyle) &&
        !publisherLayout(previousBlockStyle),
  );
}

/// Computes the horizontal width reduction (margins + borders + padding) of a
/// decorated block so `TextPainter` lays out lines at the exact inner width.
double epubBlockHorizontalInset(
  EpubBlockStyle? style,
  double fontSize, {
  double width = 0,
}) {
  if (style == null) return 0;
  final isQuote = style.kind == EpubBlockKind.blockquote;
  final isCallout = style.kind == EpubBlockKind.callout;
  final isPre = style.kind == EpubBlockKind.pre;
  final isList = style.kind == EpubBlockKind.listItem;
  final marginL =
      (style.marginLeftEm > 0 ? style.marginLeftEm : (isList ? 0.6 : 0.0)) *
      fontSize;
  final marginR = style.marginRightEm * fontSize;
  final pad =
      (style.paddingEm > 0
          ? style.paddingEm
          : (isQuote || isCallout
                ? 0.75
                : isPre
                ? 0.65
                : 0.0)) *
      fontSize;
  final borderL = style.borderLeftWidth > 0
      ? style.borderLeftWidth
      : (isQuote ? 3.0 : 0.0);
  final borderAll = style.borderWidth > 0
      ? style.borderWidth
      : (isCallout ? 1.0 : 0.0);
  final relative = [
    'margin-left',
    'margin-right',
    'padding-left',
    'padding-right',
  ].fold(0.0, (sum, key) => sum + (style.relativeInsets[key] ?? 0) * width);
  return marginL + marginR + pad * 2 + borderL + borderAll * 2 + relative;
}

double epubBlockTopExtra(
  EpubBlockStyle? style,
  double fontSize, {
  double width = 0,
}) {
  if (style == null) return 0;
  final isQuote = style.kind == EpubBlockKind.blockquote;
  final isCallout = style.kind == EpubBlockKind.callout;
  final isPre = style.kind == EpubBlockKind.pre;
  final padTopEm = style.effectivePaddingTopEm;
  final pad =
      (padTopEm > 0
          ? padTopEm
          : (isQuote || isCallout || isPre
                ? 0.55
                : style.borderTopWidth > 0
                ? 0.25
                : 0.0)) *
      fontSize;
  final borderT = style.borderTopWidth > 0
      ? style.borderTopWidth
      : (style.borderWidth > 0 ? style.borderWidth : (isCallout ? 1.0 : 0.0));
  return pad + borderT + (style.relativeInsets['padding-top'] ?? 0) * width;
}

double epubBlockBottomExtra(
  EpubBlockStyle? style,
  double fontSize, {
  double width = 0,
}) {
  if (style == null) return 0;
  final isQuote = style.kind == EpubBlockKind.blockquote;
  final isCallout = style.kind == EpubBlockKind.callout;
  final isPre = style.kind == EpubBlockKind.pre;
  final padBottomEm = style.effectivePaddingBottomEm;
  final pad =
      (padBottomEm > 0
          ? padBottomEm
          : (isQuote || isCallout || isPre
                ? 0.55
                : style.borderBottomWidth > 0
                ? 0.25
                : 0.0)) *
      fontSize;
  final borderB = style.borderBottomWidth > 0
      ? style.borderBottomWidth
      : (style.borderWidth > 0 ? style.borderWidth : (isCallout ? 1.0 : 0.0));
  return pad + borderB + (style.relativeInsets['padding-bottom'] ?? 0) * width;
}

/// CSS rule content height and border occupy one shared extent in scroll and
/// paged rendering; an explicit thin rule must not reserve a default text row.
double readerHorizontalRuleExtent(
  EpubBlockStyle? style,
  double fontSize, {
  double defaultHeight = 28,
}) {
  if (style?.ruleHeightEm == null) return defaultHeight;
  final border = style!.borderTopWidth > 0
      ? style.borderTopWidth
      : style.borderBottomWidth > 0
      ? style.borderBottomWidth
      : style.borderWidth;
  return math.max(1.0, style.ruleHeightEm! * fontSize) +
      (border * fontSize / 16).clamp(0.0, 14.0);
}

/// Slices and shifts [spans] to the substring range `[start, end)`.
List<EpubInlineSpan> sliceEpubSpans(
  List<EpubInlineSpan> spans,
  int start,
  int end,
) {
  if (spans.isEmpty || end <= start) return const [];
  final sliced = <EpubInlineSpan>[];
  for (final s in spans) {
    if (s.end <= start || s.start >= end) continue;
    final newStart = math.max(0, s.start - start);
    final newEnd = math.min(end - start, s.end - start);
    if (newEnd <= newStart) continue;
    sliced.add(s.copyWithRange(newStart, newEnd));
  }
  return sliced;
}

/// Resolves the display size of an inline `<img>` placeholder (`\uFFFC`).
Size resolveInlineImageSize(
  EpubInlineSpan span,
  double fontSize,
  Map<String, Size> localImageSizes,
) {
  final url = span.inlineImageUrl;
  final natural = url != null ? localImageSizes[url] : null;
  final layout = span.inlineImageLayout;
  if (natural != null) {
    if (layout != null && !layout.isEmpty) {
      return layout.resolve(
        natural: natural,
        available: Size(fontSize * 12, fontSize * 4),
        fontSize: fontSize,
      );
    }
    final maxInlineHeight = fontSize * 1.35;
    if (natural.height <= maxInlineHeight &&
        natural.width <= fontSize * 4 &&
        natural.height > 0 &&
        natural.width > 0) {
      return natural;
    }
    final ratio = natural.height > 0 ? natural.width / natural.height : 1.0;
    final h = math.min(natural.height, maxInlineHeight);
    return Size((h * ratio).clamp(4.0, fontSize * 6), h.clamp(4.0, fontSize * 3));
  }
  if (layout != null && !layout.isEmpty) {
    return layout.resolve(
      natural: Size(fontSize, fontSize),
      available: Size(fontSize * 12, fontSize * 4),
      fontSize: fontSize,
    );
  }
  return Size(fontSize, fontSize);
}

/// Builds both the [TextSpan] tree and matching [PlaceholderDimensions] for
/// either `TextPainter` measurement (`forMeasurement: true`) or `Text.rich`
/// rendering (`forMeasurement: false`).
({TextSpan span, List<PlaceholderDimensions> dimensions})
buildRichParagraphSpans({
  required String text,
  required TextStyle style,
  required bool indent,
  double indentEm = 2.0,
  double? continuationWidth,
  double? scaledFontSize,
  List<EpubInlineSpan> spans = const [],
  Map<String, EpubFootnote> footnotes = const {},
  Map<String, String> embeddedFonts = const {},
  int? bookId,
  Map<String, Size> localImageSizes = const {},
  Color? paperColor,
  Color? onPaperColor,
  Color? accentColor,
  ({int start, int end, Color color})? highlight,
  ValueChanged<EpubFootnote>? onTapFootnote,
  bool forMeasurement = false,
  bool allowRubyWidgetSpan = false,
  bool allowFootnoteWidgetSpan = false,
}) {
  final baseFont = style.fontSize ?? 19.0;
  final metricFont = scaledFontSize ?? baseFont;
  final effectiveIndentEm = indent ? indentEm : 0.0;
  final dimensions = <PlaceholderDimensions>[
    if (effectiveIndentEm > 0)
      PlaceholderDimensions(
        size: Size(metricFont * effectiveIndentEm, 0),
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        baselineOffset: 0,
      ),
  ];

  List<InlineSpan> emitPlainRange(
    int rangeStart,
    int rangeEnd, [
    TextStyle? spanStyle,
  ]) {
    if (rangeEnd <= rangeStart) return const [];
    if (highlight == null ||
        highlight.end <= rangeStart ||
        highlight.start >= rangeEnd) {
      return [
        TextSpan(text: text.substring(rangeStart, rangeEnd), style: spanStyle),
      ];
    }
    final hStart = highlight.start.clamp(rangeStart, rangeEnd);
    final hEnd = highlight.end.clamp(hStart, rangeEnd);
    final highlightedStyle = (spanStyle ?? const TextStyle()).copyWith(
      backgroundColor: highlight.color,
    );
    return [
      if (hStart > rangeStart)
        TextSpan(text: text.substring(rangeStart, hStart), style: spanStyle),
      if (hEnd > hStart)
        TextSpan(
          text: text.substring(hStart, hEnd),
          style: highlightedStyle,
        ),
      if (rangeEnd > hEnd)
        TextSpan(text: text.substring(hEnd, rangeEnd), style: spanStyle),
    ];
  }

  if (spans.isEmpty) {
    return (
      span: readerParagraphSpan(
        children: emitPlainRange(0, text.length),
        style: style,
        indent: effectiveIndentEm > 0,
        indentEm: effectiveIndentEm,
        continuationWidth: continuationWidth,
      ),
      dimensions: dimensions,
    );
  }

  final effectivePaper = paperColor ?? const Color(0xFFFDFBF7);
  final effectiveOnPaper =
      onPaperColor ?? style.color ?? const Color(0xFF1F1D1A);
  final effectiveAccent = accentColor ?? const Color(0xFF8C6239);

  final children = <InlineSpan>[];
  var cursor = 0;

  for (final s in spans) {
    final sStart = s.start.clamp(cursor, text.length);
    final sEnd = s.end.clamp(sStart, text.length);
    if (sStart > cursor) {
      children.addAll(emitPlainRange(cursor, sStart));
    }
    if (sEnd <= sStart) {
      cursor = sEnd;
      continue;
    }

    // 1. Inline image (\uFFFC placeholder)
    if (s.inlineImageUrl != null) {
      final widgetSize = resolveInlineImageSize(s, baseFont, localImageSizes);
      final metricSize = resolveInlineImageSize(s, metricFont, localImageSizes);
      dimensions.add(
        PlaceholderDimensions(
          size: metricSize,
          alignment: PlaceholderAlignment.middle,
        ),
      );
      final footnote = s.footnoteId != null ? footnotes[s.footnoteId!] : null;
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: forMeasurement
              ? SizedBox.fromSize(size: widgetSize)
              : ReaderInlineImageWidget(
                  url: s.inlineImageUrl!,
                  size: widgetSize,
                  footnote: footnote,
                  onTapFootnote: onTapFootnote,
                ),
        ),
      );
      cursor = sEnd;
      continue;
    }

    // Build styled TextStyle for this inline span.
    var spanStyle = const TextStyle();
    final scale =
        (s.fontScale ?? 1.0) *
        (s.superscript || s.subscript ? 0.78 : 1.0) *
        (s.code ? 0.92 : 1.0);
    if ((scale - 1.0).abs() > 0.01) {
      spanStyle = spanStyle.copyWith(fontSize: baseFont * scale);
    }
    if (s.bold) {
      spanStyle = spanStyle.copyWith(fontWeight: FontWeight.w700);
    }
    if (s.italic) {
      spanStyle = spanStyle.copyWith(fontStyle: FontStyle.italic);
    }
    if (s.underline || s.strike) {
      Color? decColor;
      if (s.underlineColor != null) {
        decColor = EpubColorAdapter.adaptBorderColor(
          Color(s.underlineColor!),
          paperColor: effectivePaper,
          defaultTextColor: effectiveOnPaper,
        );
      }
      final decStyle = switch (s.underlineStyle) {
        'dotted' => TextDecorationStyle.dotted,
        'dashed' => TextDecorationStyle.dashed,
        'double' => TextDecorationStyle.double,
        _ => null,
      };
      spanStyle = spanStyle.copyWith(
        decoration: TextDecoration.combine([
          if (s.underline && s.underlineOffsetEm == null) TextDecoration.underline,
          if (s.strike) TextDecoration.lineThrough,
        ]),
        decorationColor: decColor,
        decorationStyle: decStyle,
      );
    }
    if (s.code) {
      spanStyle = spanStyle.copyWith(
        fontFamily: 'monospace',
        backgroundColor: effectiveOnPaper.withValues(alpha: 0.08),
      );
    } else if (s.fontFamily != null) {
      final loaded = EpubFontManager.resolveFontFamily(
        bookId,
        s.fontFamily,
        embeddedFonts,
      );
      final fallbacks = EpubFontManager.fontFamilyFallbacksFor(s.fontFamily);
      spanStyle = spanStyle.copyWith(
        fontFamily: loaded ?? s.fontFamily,
        fontFamilyFallback: fallbacks,
      );
    }
    if (s.textColor != null) {
      spanStyle = spanStyle.copyWith(
        color: EpubColorAdapter.adaptTextColor(
          Color(s.textColor!),
          paperColor: effectivePaper,
          defaultTextColor: effectiveOnPaper,
          backgroundColor: s.backgroundColor != null
              ? Color(s.backgroundColor!)
              : null,
        ),
      );
    }
    if (s.backgroundColor != null) {
      final bg = EpubColorAdapter.adaptBackgroundColor(
        Color(s.backgroundColor!),
        paperColor: effectivePaper,
        defaultTextColor: effectiveOnPaper,
        isInlineBadge: true,
      );
      if (bg != null) {
        spanStyle = spanStyle.copyWith(backgroundColor: bg);
      }
    }

    final spanText = text.substring(sStart, sEnd);
    final isHighlighted =
        highlight != null && highlight.end > sStart && highlight.start < sEnd;

    // 2. Footnote reference badge / superscript
    if (s.footnoteId != null &&
        !s.footnoteId!.startsWith('epub-link:') &&
        !s.footnoteId!.startsWith('epub-action:')) {
      final footnote = footnotes[s.footnoteId!];
      if (!forMeasurement &&
          allowFootnoteWidgetSpan &&
          footnote != null &&
          onTapFootnote != null) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: ReaderFootnoteBadge(
              label: spanText,
              style: style.merge(spanStyle),
              accentColor: effectiveAccent,
              highlightColor: isHighlighted ? highlight.color : null,
              onTap: () => onTapFootnote(footnote),
            ),
          ),
        );
        cursor = sEnd;
        continue;
      }
      spanStyle = spanStyle.copyWith(
        fontSize: baseFont * 0.78,
        fontWeight: FontWeight.w700,
        color: effectiveAccent,
        backgroundColor: effectiveAccent.withValues(alpha: 0.12),
      );
    }

    // 3. Ruby (<ruby><rt>) annotation
    if (s.rubyText != null && s.rubyText!.isNotEmpty) {
      if (!forMeasurement && allowRubyWidgetSpan) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ReaderRubySpanWidget(
              baseText: spanText,
              rubyText: s.rubyText!,
              style: style.merge(spanStyle),
              highlightColor: isHighlighted ? highlight.color : null,
            ),
          ),
        );
        cursor = sEnd;
        continue;
      }
      spanStyle = spanStyle.copyWith(
        height: math.max(style.height ?? 1.72, 2.05),
      );
    }

    children.addAll(emitPlainRange(sStart, sEnd, spanStyle));
    cursor = sEnd;
  }

  if (cursor < text.length) {
    children.addAll(emitPlainRange(cursor, text.length));
  }

  return (
    span: readerParagraphSpan(
      children: children,
      style: style,
      indent: effectiveIndentEm > 0,
      indentEm: effectiveIndentEm,
      continuationWidth: continuationWidth,
    ),
    dimensions: dimensions,
  );
}

/// Renders `<ruby>` base characters with compact `<rt>` furigana/pinyin centered above.
class ReaderRubySpanWidget extends StatelessWidget {
  const ReaderRubySpanWidget({
    super.key,
    required this.baseText,
    required this.rubyText,
    required this.style,
    this.highlightColor,
  });

  final String baseText;
  final String rubyText;
  final TextStyle style;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 19.0;
    final rubyStyle = style.copyWith(
      fontSize: (fontSize * 0.52).clamp(8.5, 15.0),
      height: 1.05,
      letterSpacing: 0,
      color: style.color?.withValues(alpha: 0.78),
    );
    final baseStyle = style.copyWith(
      height: 1.15,
      backgroundColor: highlightColor ?? style.backgroundColor,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
         ExcludeSemantics(
          child: Text(
            rubyText,
            style: rubyStyle,
            textAlign: TextAlign.center,
            softWrap: false,
          ),
        ),
        Text(
          baseText,
          style: baseStyle,
          textAlign: TextAlign.center,
          softWrap: false,
        ),
      ],
    );
  }
}

/// Duokan-style interactive footnote superscript badge (`[1]`, `①`, `注`).
class ReaderFootnoteBadge extends StatelessWidget {
  const ReaderFootnoteBadge({
    super.key,
    required this.label,
    required this.style,
    required this.accentColor,
    required this.onTap,
    this.highlightColor,
  });

  final String label;
  final TextStyle style;
  final Color accentColor;
  final VoidCallback onTap;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 19.0;
    final badgeFont = (fontSize * 0.66).clamp(10.0, 15.0);
    final cleanLabel = label.trim().isEmpty ? '注' : label.trim();
    return Semantics(
      button: true,
      label: '脚注 $cleanLabel',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.0),
          decoration: BoxDecoration(
            color:
                highlightColor ?? accentColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.36),
              width: 0.8,
            ),
          ),
          child: Text(
            cleanLabel,
            style: style.copyWith(
              fontSize: badgeFont,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: accentColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders an inline `<img>` inside a paragraph (such as a Duokan note icon,
/// inline symbol, or glyph image) without breaking the paragraph into 3 blocks.
class ReaderInlineImageWidget extends StatefulWidget {
  const ReaderInlineImageWidget({
    super.key,
    required this.url,
    required this.size,
    this.footnote,
    this.onTapFootnote,
  });

  final String url;
  final Size size;
  final EpubFootnote? footnote;
  final ValueChanged<EpubFootnote>? onTapFootnote;

  @override
  State<ReaderInlineImageWidget> createState() =>
      _ReaderInlineImageWidgetState();
}

class _ReaderInlineImageWidgetState extends State<ReaderInlineImageWidget> {
  Future<Uint8List>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ReaderInlineImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  void _load() {
    if (widget.url.startsWith('wenku-local:')) {
      _bytesFuture = LocalBookMedia.load(widget.url);
    } else {
      _bytesFuture = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cached = LocalBookMedia.peek(widget.url);
    Widget child;
    if (cached != null) {
      child = Image.memory(
        cached,
        width: widget.size.width,
        height: widget.size.height,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    } else if (_bytesFuture != null) {
      child = FutureBuilder<Uint8List>(
        future: _bytesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Image.memory(
              snapshot.data!,
              width: widget.size.width,
              height: widget.size.height,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            );
          }
          return SizedBox.fromSize(size: widget.size);
        },
      );
    } else {
      child = SizedBox.fromSize(size: widget.size);
    }

    if (widget.footnote != null && widget.onTapFootnote != null) {
      return _NoReaderTapPreview(
        child: Semantics(
          button: true,
          label: '查看注释',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onTapFootnote!(widget.footnote!),
            child: child,
          ),
        ),
      );
    }
    return child;
  }
}

class _NoReaderTapPreview extends SingleChildRenderObjectWidget {
  const _NoReaderTapPreview({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNoReaderTapPreview();
}

class _RenderNoReaderTapPreview extends RenderProxyBox
    implements ReaderTapPreviewPolicy {
  @override
  bool allowsReaderTapPreview(Offset localPosition) => false;
}

/// Decorative horizontal rule (`<hr>`) for scene breaks and chapter dividers.
class ReaderHorizontalRule extends StatelessWidget {
  const ReaderHorizontalRule({
    super.key,
    required this.color,
    this.height,
    this.blockStyle,
    this.paperColor,
    this.fontSize = 19.0,
  });

  final Color color;
  final double? height;
  final EpubBlockStyle? blockStyle;
  final Color? paperColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = blockStyle;
    final extent = height ?? readerHorizontalRuleExtent(style, fontSize);
    final hasCustomCssRule =
        style != null &&
        (style.borderTopWidth > 0 ||
            style.borderBottomWidth > 0 ||
            style.borderWidth > 0 ||
            style.borderColor != null ||
            style.backgroundColor != null);
    if (hasCustomCssRule) {
      final effectivePaper = paperColor ?? const Color(0xFFFDFBF7);
      final rawColor = style.borderColor ?? style.backgroundColor;
      final barColor = rawColor != null
          ? EpubColorAdapter.adaptBorderColor(
              Color(rawColor),
              paperColor: effectivePaper,
              defaultTextColor: color,
            )
          : color.withValues(alpha: 0.35);
      final rawThickness = style.borderTopWidth > 0
          ? style.borderTopWidth
          : style.borderBottomWidth > 0
          ? style.borderBottomWidth
          : style.borderWidth > 0
          ? style.borderWidth
          : 2.0;
      final barHeight = (rawThickness * (fontSize / 16.0)).clamp(1.0, 14.0);
      final isDotted =
          style.borderStyle == 'dotted' || style.borderStyle == 'dashed';
      return SizedBox(
        height: extent,
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: EdgeInsets.only(
              left:
                  style.inset(
                    'margin-left',
                    style.marginLeftEm,
                    fontSize,
                    constraints.maxWidth,
                  ) +
                  style.inset(
                    'padding-left',
                    style.paddingEm,
                    fontSize,
                    constraints.maxWidth,
                  ),
              right:
                  style.inset(
                    'margin-right',
                    style.marginRightEm,
                    fontSize,
                    constraints.maxWidth,
                  ) +
                  style.inset(
                    'padding-right',
                    style.paddingEm,
                    fontSize,
                    constraints.maxWidth,
                  ),
            ),
            child: Align(
              alignment: style.ruleHeightEm != null
                  ? Alignment.topCenter
                  : Alignment.center,
              child: isDotted
                  ? CustomPaint(
                      size: Size(double.infinity, barHeight),
                      painter: _DottedBlockBorderPainter(
                        color: barColor,
                        topWidth: barHeight,
                        bottomWidth: 0,
                        dashed: style.borderStyle == 'dashed',
                      ),
                    )
                  : Container(
                      width: double.infinity,
                      height: barHeight,
                      color: barColor,
                    ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: extent,
      child: Center(
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 0.9,
                color: color.withValues(alpha: 0.22),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '❖',
                style: TextStyle(
                  fontSize: 11,
                  height: 1,
                  color: color.withValues(alpha: 0.42),
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 0.9,
                color: color.withValues(alpha: 0.22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Structured table renderer for EPUB `<table>` blocks.
class ReaderTableBlock extends StatelessWidget {
  const ReaderTableBlock({
    super.key,
    required this.rows,
    required this.style,
    required this.borderColor,
    required this.headerBackground,
  });

  final List<List<String>> rows;
  final TextStyle style;
  final Color borderColor;
  final Color headerBackground;

  @override
  Widget build(BuildContext context) {
    final columnCount = rows.fold<int>(
      0,
      (prev, r) => math.max(prev, r.length),
    );
    if (columnCount == 0) return const SizedBox.shrink();
    final cellStyle = style.copyWith(
      fontSize: (style.fontSize ?? 18) * 0.88,
      height: 1.4,
    );
    return Table(
      border: TableBorder.all(
        color: borderColor.withValues(alpha: 0.28),
        width: 0.8,
        borderRadius: BorderRadius.circular(6),
      ),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (var r = 0; r < rows.length; r++)
          TableRow(
            decoration: r == 0 && rows.length > 1
                ? BoxDecoration(color: headerBackground)
                : null,
            children: [
              for (var c = 0; c < columnCount; c++)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Text(
                    c < rows[r].length ? rows[r][c] : '',
                    style: r == 0 && rows.length > 1
                        ? cellStyle.copyWith(fontWeight: FontWeight.w700)
                        : cellStyle,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Wraps a reader block or fragment with EPUB box-model styling (blockquote
/// accent bar, callout background, borders, padding, margins, or top/bottom rule).
class ReaderBlockDecoration extends StatelessWidget {
  const ReaderBlockDecoration({
    super.key,
    required this.child,
    required this.fontSize,
    required this.paperColor,
    required this.onPaperColor,
    required this.accentColor,
    this.blockStyle,
    this.isFirstOfBlock = true,
    this.isLastOfBlock = true,
    this.includeVerticalMargins = false,
  });

  final Widget child;
  final EpubBlockStyle? blockStyle;
  final double fontSize;
  final Color paperColor;
  final Color onPaperColor;
  final Color accentColor;
  final bool isFirstOfBlock;
  final bool isLastOfBlock;
  final bool includeVerticalMargins;

  @override
  Widget build(BuildContext context) {
    if (blockStyle?.relativeInsets.isNotEmpty == true) {
      return LayoutBuilder(
        builder: (context, constraints) =>
            _buildBox(context, constraints.maxWidth),
      );
    }
    return _buildBox(context, 0);
  }

  Widget _buildBox(BuildContext context, double width) {
    final style = blockStyle;
    if (style == null) return child;

    final isQuote = style.kind == EpubBlockKind.blockquote;
    final isCallout = style.kind == EpubBlockKind.callout;
    final isPre = style.kind == EpubBlockKind.pre;
    final isList = style.kind == EpubBlockKind.listItem;

    final hasBox =
        isQuote ||
        isCallout ||
        isPre ||
        isList ||
        style.hasBoxDecoration ||
        (includeVerticalMargins &&
            (style.marginTopEm > 0 || style.marginBottomEm > 0)) ||
        style.marginLeftEm > 0 ||
        style.marginRightEm > 0 ||
        style.relativeInsets.isNotEmpty ||
        style.paddingTopEm > 0 ||
        style.paddingBottomEm > 0 ||
        style.borderTopWidth > 0 ||
        style.borderBottomWidth > 0;
    if (!hasBox) return child;

    Color? bg;
    if (style.backgroundColor != null) {
      bg = EpubColorAdapter.adaptBackgroundColor(
        Color(style.backgroundColor!),
        paperColor: paperColor,
        defaultTextColor: onPaperColor,
      );
    } else if (isQuote) {
      bg = onPaperColor.withValues(alpha: 0.04);
    } else if (isCallout) {
      bg = onPaperColor.withValues(alpha: 0.05);
    } else if (isPre) {
      bg = onPaperColor.withValues(alpha: 0.06);
    }

    final borderColor = style.borderColor != null
        ? EpubColorAdapter.adaptBorderColor(
            Color(style.borderColor!),
            paperColor: paperColor,
            defaultTextColor: onPaperColor,
          )
        : isQuote
        ? accentColor.withValues(alpha: 0.55)
        : isCallout
        ? accentColor.withValues(alpha: 0.35)
        : onPaperColor.withValues(alpha: 0.36);

    final borderL =
        style.borderLeftWidth > 0 ? style.borderLeftWidth : (isQuote ? 3.0 : 0.0);
    final borderT = isFirstOfBlock ? style.borderTopWidth : 0.0;
    final borderB = isLastOfBlock ? style.borderBottomWidth : 0.0;
    final borderAll =
        style.borderWidth > 0 ? style.borderWidth : (isCallout ? 1.0 : 0.0);
    final isDottedRule =
        (style.borderStyle == 'dotted' || style.borderStyle == 'dashed') &&
        borderAll == 0 &&
        borderL == 0 &&
        (borderT > 0 || borderB > 0);

    Border? border;
    if (borderAll > 0) {
      border = Border(
        top: isFirstOfBlock
            ? BorderSide(color: borderColor, width: borderAll)
            : BorderSide.none,
        bottom: isLastOfBlock
            ? BorderSide(color: borderColor, width: borderAll)
            : BorderSide.none,
        left: BorderSide(color: borderColor, width: borderAll),
        right: BorderSide(color: borderColor, width: borderAll),
      );
    } else if (!isDottedRule && (borderL > 0 || borderT > 0 || borderB > 0)) {
      border = Border(
        top: borderT > 0
            ? BorderSide(color: borderColor, width: borderT)
            : BorderSide.none,
        left: borderL > 0
            ? BorderSide(color: borderColor, width: borderL)
            : BorderSide.none,
        bottom: borderB > 0
            ? BorderSide(color: borderColor, width: borderB)
            : BorderSide.none,
      );
    }

    final radiusVal = style.borderRadius > 0
        ? style.borderRadius
        : (bg != null && borderL == 0 ? 8.0 : 4.0);
    final borderRadius = borderAll > 0 || (bg != null && borderL == 0)
        ? BorderRadius.vertical(
            top: isFirstOfBlock ? Radius.circular(radiusVal) : Radius.zero,
            bottom: isLastOfBlock ? Radius.circular(radiusVal) : Radius.zero,
          )
        : null;

    final padH =
        (style.paddingEm > 0
            ? style.paddingEm
            : (isQuote || isCallout
                  ? 0.75
                  : isPre
                  ? 0.65
                  : 0.0)) *
        fontSize;
    final padTopEm = style.effectivePaddingTopEm;
    final padBottomEm = style.effectivePaddingBottomEm;
    final padTop =
        (padTopEm > 0
            ? padTopEm
            : (isQuote || isCallout || isPre
                  ? 0.55
                  : borderT > 0
                  ? 0.25
                  : 0.0)) *
        fontSize;
    final padBottom =
        (padBottomEm > 0
            ? padBottomEm
            : (isQuote || isCallout || isPre
                  ? 0.55
                  : borderB > 0
                  ? 0.25
                  : 0.0)) *
        fontSize;

    final marginL =
        (style.marginLeftEm > 0 ? style.marginLeftEm : (isList ? 0.6 : 0.0)) *
            fontSize +
        (style.relativeInsets['margin-left'] ?? 0) * width;
    final marginR = style.inset(
      'margin-right',
      style.marginRightEm,
      fontSize,
      width,
    );
    final marginT = includeVerticalMargins && isFirstOfBlock
        ? (style.marginTopEm > 0
                      ? style.marginTopEm
                      : (style.isHeading ? 0.45 : 0.0)) *
                  fontSize +
              (style.relativeInsets['margin-top'] ?? 0) * width
        : 0.0;
    final marginB = includeVerticalMargins && isLastOfBlock
        ? (style.marginBottomEm > 0
                      ? style.marginBottomEm
                      : (style.isHeading ? 0.25 : 0.0)) *
                  fontSize +
              (style.relativeInsets['margin-bottom'] ?? 0) * width
        : 0.0;

    Widget boxed = Container(
      margin: EdgeInsets.fromLTRB(marginL, marginT, marginR, marginB),
      padding: EdgeInsets.fromLTRB(
        padH + (style.relativeInsets['padding-left'] ?? 0) * width,
        isFirstOfBlock
            ? padTop + (style.relativeInsets['padding-top'] ?? 0) * width
            : (isQuote || isCallout || isPre ? padTop * 0.35 : 0.0),
        padH + (style.relativeInsets['padding-right'] ?? 0) * width,
        isLastOfBlock
            ? padBottom + (style.relativeInsets['padding-bottom'] ?? 0) * width
            : (isQuote || isCallout || isPre ? padBottom * 0.35 : 0.0),
      ),
      decoration: BoxDecoration(
        color: bg,
        border: border,
        borderRadius: borderRadius,
      ),
      child: child,
    );

    if (isDottedRule) {
      boxed = CustomPaint(
        foregroundPainter: _DottedBlockBorderPainter(
          color: borderColor,
          topWidth: borderT,
          bottomWidth: borderB,
          dashed: style.borderStyle == 'dashed',
          leftInset: marginL,
          rightInset: marginR,
        ),
        child: boxed,
      );
    }
    return boxed;
  }
}

class _DottedBlockBorderPainter extends CustomPainter {
  const _DottedBlockBorderPainter({
    required this.color,
    required this.topWidth,
    required this.bottomWidth,
    this.dashed = false,
    this.leftInset = 0.0,
    this.rightInset = 0.0,
  });

  final Color color;
  final double topWidth;
  final double bottomWidth;
  final bool dashed;
  final double leftInset;
  final double rightInset;

  void _drawHorizontalRule(
    Canvas canvas,
    double y,
    double startX,
    double endX,
    double strokeWidth,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = dashed ? StrokeCap.butt : StrokeCap.round;
    final dashLen = dashed
        ? math.max(4.0, strokeWidth * 3.0)
        : math.max(1.2, strokeWidth);
    final gapLen = dashed
        ? math.max(3.0, strokeWidth * 2.0)
        : math.max(2.6, strokeWidth * 2.4);
    var x = startX;
    while (x < endX) {
      final nextX = math.min(x + dashLen, endX);
      canvas.drawLine(Offset(x, y), Offset(nextX, y), paint);
      x += dashLen + gapLen;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final startX = leftInset;
    final endX = math.max(startX, size.width - rightInset);
    if (topWidth > 0) {
      _drawHorizontalRule(canvas, topWidth / 2, startX, endX, topWidth);
    }
    if (bottomWidth > 0) {
      _drawHorizontalRule(
        canvas,
        size.height - bottomWidth / 2,
        startX,
        endX,
        bottomWidth,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DottedBlockBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.topWidth != topWidth ||
      oldDelegate.bottomWidth != bottomWidth ||
      oldDelegate.dashed != dashed ||
      oldDelegate.leftInset != leftInset ||
      oldDelegate.rightInset != rightInset;
}
