import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:tategaki/tategaki.dart'
    show CharacterClassifier, RotationRules, KinsokuProcessor;
import 'epub_rich_layout.dart';
import 'epub_image_styles.dart';
import 'reader_content.dart';
import 'reader_text.dart';
import 'reader_preferences.dart';
import 'local_book_media.dart';
import 'local_image_layout.dart';
import 'reader_block_spacing.dart';
import 'reader_rich_content.dart';

// A vertical typographic substitution only. Source text, selection offsets,
// copied quotations and bookmarks retain the original characters.
String _verticalCluster(String source) => switch (source) {
  '“' => '「',
  '”' => '」',
  '‘' => '『',
  '’' => '』',
  _ => source,
};

class ReaderTextAnchor {
  const ReaderTextAnchor(this.paragraph, this.offset);
  final int paragraph, offset;
}

class ReaderPageFragment {
  const ReaderPageFragment({
    required this.paragraph,
    required this.start,
    required this.end,
    required this.text,
    required this.rect,
    this.indent = false,
    this.indentEm = 2.0,
    this.image = false,
    this.rule = false,
    this.lineMetrics,
    this.blockStyle,
    this.spans = const [],
    this.isLeadingHeading = false,
    this.isFirstOfBlock = true,
    this.isLastOfBlock = true,
  });
  final int paragraph, start, end;
  final String text;
  final Rect rect;
  final bool indent, image;
  final double indentEm;
  final bool rule;
  final ReaderFragmentLines? lineMetrics;
  final EpubBlockStyle? blockStyle;
  final List<EpubInlineSpan> spans;
  final bool isLeadingHeading;
  final bool isFirstOfBlock;
  final bool isLastOfBlock;
  int get lineCount => lineMetrics?.count ?? 1;
  Iterable<ReaderPageLine> get lines =>
      lineMetrics?.values ?? [ReaderPageLine(start, end, 0, rect.height)];
  ReaderPageFragment shift(Offset delta) => ReaderPageFragment(
    paragraph: paragraph,
    start: start,
    end: end,
    text: text,
    rect: rect.shift(delta),
    indent: indent,
    indentEm: indentEm,
    image: image,
    rule: rule,
    lineMetrics: lineMetrics,
    blockStyle: blockStyle,
    spans: spans,
    isLeadingHeading: isLeadingHeading,
    isFirstOfBlock: isFirstOfBlock,
    isLastOfBlock: isLastOfBlock,
  );
}

/// Source boundaries and local line boxes reuse the compact shaping metrics.
/// Only visible reflow builds line objects; pagination does not retain a widget
/// or a native LineMetrics object for every line in a chapter.
class ReaderPageLine {
  const ReaderPageLine(this.start, this.end, this.top, this.height);
  final int start, end;
  final double top, height;
}

class ReaderFragmentLines {
  const ReaderFragmentLines._(
    this._metrics,
    this._first,
    this._end,
    this._prefix,
    this._sourceLength,
  );
  final _HorizontalMetrics _metrics;
  final int _first, _end, _prefix, _sourceLength;
  int get count => _end - _first;
  Iterable<ReaderPageLine> get values sync* {
    var top = 0.0;
    for (var i = _first; i < _end; i++) {
      final start = (_metrics.starts[i] - _prefix).clamp(0, _sourceLength);
      final end = (_metrics.starts[i + 1] - _prefix).clamp(
        start,
        _sourceLength,
      );
      final height = _metrics.heights[i];
      yield ReaderPageLine(start, end, top, height);
      top += height;
    }
  }
}

class ReaderVerticalGlyph {
  const ReaderVerticalGlyph({
    required this.text,
    required this.start,
    required this.end,
    required this.paragraph,
    required this.sourceStart,
    required this.sourceEnd,
    required this.rect,
    required this.rotation,
    this.ruby = '',
    this.note,
    this.emphasis = 0,
    this.opacity = 1,
    this.scale = 1.0,
    this.bold = false,
    this.italic = false,
    this.textColor,
    this.rubyText,
    this.footnoteId,
    this.isBlockquote = false,
    this.fontFamily,
  });
  final String text;
  final int start, end, paragraph, sourceStart, sourceEnd;
  final Rect rect;
  final double rotation;
  final String ruby;
  final String? note;
  final int emphasis;
  final double opacity;
  final double scale;
  final bool bold;
  final bool italic;
  final int? textColor;
  final String? rubyText;
  final String? footnoteId;
  final bool isBlockquote;
  final String? fontFamily;
}

class ReaderLeaf {
  ReaderLeaf(
    List<ReaderPageFragment> fragments, {
    this.text = '',
    List<ReaderVerticalGlyph> glyphs = const [],
    this.vertical = false,
  }) : fragments = List.unmodifiable(fragments),
       _glyphs = List.unmodifiable(glyphs),
       _columns = const [],
       _glyphCache = null;
  ReaderLeaf._vertical(
    List<ReaderPageFragment> fragments,
    this.text,
    List<_VerticalColumn> columns,
    this._glyphCache,
  ) : vertical = true,
      fragments = List.unmodifiable(fragments),
      _columns = List.unmodifiable(columns),
      _glyphs = const [];
  final List<ReaderPageFragment> fragments;
  final bool vertical;
  final String text;
  final List<ReaderVerticalGlyph> _glyphs;
  final List<_VerticalColumn> _columns;
  final _ReaderVerticalPageCache? _glyphCache;
  List<ReaderVerticalGlyph> get glyphs => _glyphCache?.forPage(this) ?? _glyphs;
  ReaderTextAnchor get anchor {
    if (fragments.isEmpty) return const ReaderTextAnchor(0, 0);
    for (final f in fragments) {
      if (!f.isLeadingHeading) {
        return ReaderTextAnchor(f.paragraph, f.start);
      }
    }
    return const ReaderTextAnchor(0, 0);
  }
}

class ReaderPagination {
  ReaderPagination(this.pages, this.size) : _glyphCache = null;
  ReaderPagination._measured(this.pages, this.size, this._glyphCache);
  final List<ReaderLeaf> pages;
  final Size size;
  final _ReaderVerticalPageCache? _glyphCache;
  @visibleForTesting
  int get debugGlyphPageBuilds => _glyphCache?.pageBuilds ?? 0;
  @visibleForTesting
  int get debugResidentGlyphPages => _glyphCache?._pages.length ?? 0;
  @visibleForTesting
  int get debugResidentGlyphCount =>
      _glyphCache?._pages.values.fold<int>(
        0,
        (count, glyphs) => count + glyphs.length,
      ) ??
      0;
  int pageFor(ReaderTextAnchor anchor) {
    var nearest = 0;
    for (var p = 0; p < pages.length; p++) {
      for (final f in pages[p].fragments) {
        if (f.isLeadingHeading) {
          if (anchor.paragraph == f.paragraph && anchor.offset == 0) return p;
          continue;
        }
        if (f.paragraph == anchor.paragraph &&
            (f.image || anchor.offset >= f.start && anchor.offset < f.end)) {
          return p;
        }
        if (f.paragraph < anchor.paragraph ||
            f.paragraph == anchor.paragraph && f.start <= anchor.offset) {
          nearest = p;
        }
      }
    }
    return nearest;
  }
}

class _HorizontalMetrics {
  _HorizontalMetrics(List<ui.LineMetrics> lines, List<int> starts)
    : heights = Float64List(lines.length),
      starts = Uint32List.fromList(starts) {
    for (var i = 0; i < lines.length; i++) {
      heights[i] = lines[i].height;
    }
  }
  // Repacking only needs exact line heights and source boundaries. Do not keep
  // every native line descriptor's baseline, width, ascent and other fields.
  final Float64List heights;
  final Uint32List starts;
}

class _VerticalMetrics {
  _VerticalMetrics(
    this.clusters,
    this.offsets,
    this.advances,
    this.rotations,
    this.annotations,
  );
  final List<String> clusters;
  final Uint32List offsets;
  // Repeated glyphs share their boxed advances/rotations from the metric map.
  // Tight reference lists are smaller than duplicating a double per position
  // on pointer-compressed Android runtimes, and retain the same exact values.
  final List<double> advances, rotations;
  final ReaderRichParagraphIndex? annotations;
}

class _VerticalColumn {
  const _VerticalColumn({
    required this.metrics,
    required this.paragraph,
    required this.first,
    required this.end,
    required this.pageStart,
    required this.left,
    required this.indent,
    required this.font,
    required this.extra,
    required this.format,
    this.blockStyle,
    this.paragraphSpans = const [],
    this.blockScale = 1.0,
    this.resolvedFamily,
    this.isLeadingHeading = false,
  });
  final _VerticalMetrics metrics;
  final int paragraph, first, end, pageStart;
  final double left, indent, font, extra;
  final ReaderRichParagraph format;
  final EpubBlockStyle? blockStyle;
  final List<EpubInlineSpan> paragraphSpans;
  final double blockScale;
  final String? resolvedFamily;
  final bool isLeadingHeading;
}

/// Keep complete page boundaries for progress, seeking and bookmarks, but build
/// per-character drawing objects only when a leaf is used. Six leaves cover the
/// current and neighbouring two-page spreads; reading a long chapter does not
/// accumulate every visited page's glyph rectangles.
class _ReaderVerticalPageCache {
  final _pages = <ReaderLeaf, List<ReaderVerticalGlyph>>{};
  int pageBuilds = 0;

  List<ReaderVerticalGlyph> forPage(ReaderLeaf page) {
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      return cached;
    }
    final glyphs = <ReaderVerticalGlyph>[];
    for (final column in page._columns) {
      final metrics = column.metrics;
      final annotations = metrics.annotations;
      final sourceStart = metrics.offsets[column.first];
      final blockStyle = column.blockStyle;
      final paragraphSpans = column.paragraphSpans;
      var y = column.indent;
      for (var c = column.first; c < column.end; c++) {
        if (metrics.clusters[c] == '\n') continue;
        final cStart = metrics.offsets[c];
        final cEnd = metrics.offsets[c + 1];
        EpubInlineSpan? activeSpan;
        String? spanRuby;
        if (paragraphSpans.isNotEmpty) {
          for (final s in paragraphSpans) {
            if (s.start < cEnd && s.end > cStart) {
              activeSpan = s;
              if (s.rubyText != null && s.start == cStart) {
                spanRuby = s.rubyText;
              }
              break;
            }
          }
        }
        final spanScale =
            (activeSpan?.fontScale ?? 1.0) *
            (activeSpan != null &&
                    (activeSpan.superscript ||
                        activeSpan.subscript ||
                        activeSpan.footnoteId != null)
                ? 0.78
                : 1.0);
        final glyphScale = column.blockScale * spanScale;
        final isBold =
            (blockStyle?.isHeading ?? false) ||
            (blockStyle?.fontWeight ?? 400) >= 600 ||
            (activeSpan?.bold ?? false);
        final isItalic =
            (blockStyle?.italic ?? false) || (activeSpan?.italic ?? false);
        final textColor = activeSpan?.textColor ?? blockStyle?.textColor;
        final formatRuby = annotations?.rubyAt(cStart, cEnd) ?? '';
        final formatNote = annotations?.noteAt(cStart, cEnd);
        final effectiveRuby = formatRuby.isNotEmpty
            ? formatRuby
            : (spanRuby ?? '');
        final effectiveNote = formatNote ?? activeSpan?.footnoteId;
        final glyphFont = column.font * spanScale;
        final glyphLeft = (spanScale - 1.0).abs() > 0.01
            ? column.left + (column.font - glyphFont) / 2
            : column.left;

        glyphs.add(
          ReaderVerticalGlyph(
            text: _verticalCluster(metrics.clusters[c]),
            start: column.pageStart + cStart - sourceStart,
            end: column.pageStart + cEnd - sourceStart,
            paragraph: column.paragraph,
            sourceStart: column.isLeadingHeading ? 0 : cStart,
            sourceEnd: column.isLeadingHeading ? 0 : cEnd,
            rect: Rect.fromLTWH(
              glyphLeft,
              y,
              glyphFont,
              metrics.advances[c],
            ),
            rotation: metrics.rotations[c],
            emphasis: annotations?.emphasisAt(cStart) ?? 0,
            opacity: column.format.opacity,
            ruby: effectiveRuby,
            note: effectiveNote,
            scale: glyphScale,
            bold: isBold,
            italic: isItalic,
            textColor: textColor,
            rubyText: spanRuby ?? (formatRuby.isNotEmpty ? formatRuby : null),
            footnoteId: effectiveNote,
            isBlockquote: blockStyle?.kind == EpubBlockKind.blockquote,
            fontFamily: activeSpan?.fontFamily ?? column.resolvedFamily,
          ),
        );
        y += metrics.advances[c] + column.extra;
      }
    }
    final result = List<ReaderVerticalGlyph>.unmodifiable(glyphs);
    _pages[page] = result;
    if (_pages.length > 6) _pages.remove(_pages.keys.first);
    pageBuilds++;
    return result;
  }
}

class _ReaderMeasurements {
  final horizontal = <int, _HorizontalMetrics>{};
  final vertical = <int, _VerticalMetrics>{};
  final glyphs = <(String, int), ({double advance, double rotation})>{};
  final complexGraphemes = <String, String>{};
}

/// A height change re-packs measured lines/columns; it must not shape an entire
/// chapter again. Two typography/width configurations are retained per reader.
class ReaderTextLayoutCache {
  final _layouts = <Object, _ReaderMeasurements>{};
  int paragraphMeasurements = 0;
  _ReaderMeasurements _for(Object key) {
    final cached = _layouts.remove(key);
    if (cached != null) {
      _layouts[key] = cached;
      return cached;
    }
    if (_layouts.length == 2) _layouts.remove(_layouts.keys.first);
    return _layouts[key] = _ReaderMeasurements();
  }
}

/// Keep publisher bleed pages and plate previews independent of prose margins,
/// while retaining the host's safe area and footer space.
EdgeInsets readerPublisherPagePadding(
  ReaderContent content,
  ReaderPreferences preferences,
  EdgeInsets padding,
) {
  if (preferences.mode != ReaderMode.paged ||
      !content.hasHorizontalBleed && !content.imageOnly) {
    return padding;
  }
  return EdgeInsets.fromLTRB(
    math.max(0, padding.left - preferences.leftMargin),
    content.imageOnly ? padding.top - preferences.marginTop + 32 : padding.top,
    math.max(0, padding.right - preferences.rightMargin),
    content.imageOnly
        ? padding.bottom - preferences.marginBottom + 8
        : padding.bottom,
  );
}

/// Actual line/glyph boundaries, not viewport-sized scroll jumps. Only the
/// current chapter is measured, yielding between bounded chunks of work.
Future<ReaderPagination?> paginateReader({
  required ReaderContent content,
  required Size size,
  required TextStyle style,
  required ReaderPreferences preferences,
  required TextScaler scaler,
  required bool Function() current,
  ReaderTextAnchor? pageBreak,
  bool pageMarginsInside = false,
  ReaderTextLayoutCache? cache,
  Map<String, Size> localImageSizes = const {},
  int? bookId,
  bool userSelectedCustomFont = false,
}) async {
  final pages = <ReaderLeaf>[];
  var fragments = <ReaderPageFragment>[];
  var columns = <_VerticalColumn>[];
  var pageText = StringBuffer();
  var previousParagraph = -1;
  var y = 0.0;
  var floatBottom = 0.0;
  var floatWidth = 0.0;
  var firstFloatParagraph = false;
  var right = size.width;
  final clock = Stopwatch()..start();
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    textAlign: preferences.justify ? TextAlign.justify : TextAlign.start,
  );
  final epubLayout = content.epubLayout;
  final baseVertical = preferences.mode == ReaderMode.vertical;
  final latinOrientation = baseVertical
      ? preferences.verticalLatinOrientation
      : ReaderVerticalLatinOrientation.rotated;
  var vertical = baseVertical;
  var forcePageBreak = false;
  ReaderRichParagraph? previousFormat;
  EpubBlockStyle? previousEpubBlock;
  var previousImage = false;
  final glyphCache =
      baseVertical || content.formats.values.any((f) => f.writing == 'vertical')
      ? _ReaderVerticalPageCache()
      : null;
  final font = scaler.scale(style.fontSize ?? 19);
  final columnWidth = font * (style.height ?? 1.72);
  final verticalStyle = style.copyWith(
    fontSize: font,
    height: 1,
    letterSpacing: 0,
  );
  final measured =
      cache?._for((
        content,
        pageMarginsInside,
        pageMarginsInside
            ? (preferences.leftMargin, preferences.rightMargin)
            : null,
        !baseVertical ||
                content.formats.values.any((f) => f.writing == 'horizontal')
            ? size.width
            : null,
        vertical ? verticalStyle : style,
        preferences.mode,
        baseVertical ? latinOrientation : null,
        vertical ? null : preferences.indent,
        vertical ? null : preferences.justify,
        vertical ? preferences.letterSpacing : null,
        scaler.scale(style.fontSize ?? 19),
        epubLayout == null ? null : userSelectedCustomFont,
      )) ??
      _ReaderMeasurements();
  final glyphMetrics = measured.glyphs;
  void flush() {
    if (fragments.isEmpty) return;
    if (!vertical &&
        columns.isEmpty &&
        fragments.any((f) => f.image) &&
        !fragments.any(
          (f) => (f.blockStyle?.relativeInsets['margin-top'] ?? 0) > 0,
        ) &&
        !fragments.any((f) => f.blockStyle?.floatRightWidthFraction != null) &&
        fragments.every(
          (f) => f.image || f.blockStyle?.kind == EpubBlockKind.figcaption,
        )) {
      final minTop = fragments.map((f) => f.rect.top).reduce(math.min);
      final maxBottom = fragments.map((f) => f.rect.bottom).reduce(math.max);
      final contentHeight = maxBottom - minTop;
      if (contentHeight > 0 && contentHeight < size.height) {
        final dy = (size.height - contentHeight) / 2 - minTop;
        if (dy.abs() > 0.5) {
          fragments = [for (final f in fragments) f.shift(Offset(0, dy))];
        }
      }
    }
    final text = pageText.toString();
    pages.add(
      columns.isEmpty
          ? ReaderLeaf(fragments, text: text, vertical: vertical)
          : ReaderLeaf._vertical(fragments, text, columns, glyphCache),
    );
    fragments = [];
    columns = [];
    pageText = StringBuffer();
    previousParagraph = -1;
    y = 0;
    floatBottom = 0;
    floatWidth = 0;
    firstFloatParagraph = false;
    right = size.width;
  }

  Future<bool> layoutBlock({
    required int index,
    required String text,
    required ReaderRichParagraph format,
    required EpubBlockStyle? blockStyle,
    required List<EpubInlineSpan> paragraphSpans,
    required bool isLeadingHeading,
  }) async {
    if (!current()) return false;
    final nextVertical = switch (format.writing) {
      'vertical' => true,
      'horizontal' => false,
      _ => baseVertical,
    };
    // The host gives bleed chapters a full paper canvas. Only ordinary
    // blocks keep the user's page margins; publisher bleed boxes keep theirs.
    final insetLeft =
        !nextVertical &&
            pageMarginsInside &&
            blockStyle?.horizontalBleed != true
        ? preferences.leftMargin
        : 0.0;
    final insetRight =
        !nextVertical &&
            pageMarginsInside &&
            blockStyle?.horizontalBleed != true
        ? preferences.rightMargin
        : 0.0;
    final blockWidth = math.max(1.0, size.width - insetLeft - insetRight);
    void addBlockFragment(ReaderPageFragment fragment) => fragments.add(
      insetLeft == 0 ? fragment : fragment.shift(Offset(insetLeft, 0)),
    );
    if (forcePageBreak ||
        format.breakBefore ||
        (blockStyle?.pageBreakBefore ?? false)) {
      flush();
      previousFormat = null;
      previousEpubBlock = null;
      previousImage = false;
    }
    forcePageBreak = format.breakAfter || (blockStyle?.pageBreakAfter ?? false);
    if (nextVertical != vertical) {
      flush();
      vertical = nextVertical;
      previousFormat = null;
      previousEpubBlock = null;
      previousImage = false;
    }
    final publisherPreview =
        readerIllustrationUrl(text) != null &&
        ((blockStyle?.sideBySideImageUrls.length ?? 0) >= 2 ||
            content.imageOnly &&
                LocalImageLayout.fromParagraph(text).containerInset == '24px');
    // Percentage plate spacing belongs to the preview container, whose fixed
    // paper gutters have already been removed from the image's width.
    final spacingWidth = publisherPreview
        ? math.max(1.0, blockWidth - readerPublisherImageGutter * 2)
        : blockWidth;
    var gap = readerEpubGapBefore(
      format: format,
      previous: previousFormat,
      blockStyle: blockStyle,
      previousBlockStyle: previousEpubBlock,
      image: readerIllustrationUrl(text) != null,
      previousImage: previousImage,
      font: font,
      lineHeight: style.height ?? 1.72,
      width: vertical ? size.height : spacingWidth,
      defaultGap: preferences.paragraphGap,
      overrideGap: preferences.paragraphGapOverride,
    );
    if (firstFloatParagraph && readerIllustrationUrl(text) == null) {
      gap = (blockStyle?.marginTopEm ?? 0) * font;
      firstFloatParagraph = false;
    }
    if (vertical) {
      right -= math.min(gap, math.max(0.0, blockWidth - columnWidth));
    } else {
      y += math.min(
        gap,
        math.max(
          0.0,
          size.height - font * math.max(style.height ?? 1.72, 2.15),
        ),
      );
    }
    previousFormat = format;
    previousEpubBlock = blockStyle;
    previousImage = readerIllustrationUrl(text) != null;

    if (!vertical &&
        y < floatBottom &&
        (format.rule ||
            blockStyle?.kind == EpubBlockKind.hr ||
            blockStyle?.kind == EpubBlockKind.table ||
            readerIllustrationUrl(text) != null)) {
      y = floatBottom;
    }

    if (format.rule || blockStyle?.kind == EpubBlockKind.hr) {
      final defaultExtent = blockStyle?.kind == EpubBlockKind.hr && !format.rule
          ? math.max(font * 1.5, 28.0)
          : font * 1.25;
      final extent = readerHorizontalRuleExtent(
        blockStyle,
        font,
        defaultHeight: defaultExtent,
      );
      if ((!vertical && y + extent > size.height ||
              vertical && right < extent) &&
          fragments.isNotEmpty) {
        flush();
      }
      addBlockFragment(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: vertical
              ? Rect.fromLTWH(right - extent, 0, extent, size.height)
              : Rect.fromLTWH(0, y, blockWidth, extent),
          rule: true,
          blockStyle: blockStyle,
          isLeadingHeading: isLeadingHeading,
        ),
      );
      if (vertical) {
        right -= extent;
      } else {
        y += extent;
      }
      return true;
    }

    if (!vertical &&
        blockStyle?.kind == EpubBlockKind.table &&
        blockStyle!.tableRows.isNotEmpty) {
      final rowHeight = font * 1.45 + 14.0;
      final tableHeight = math.min(
        size.height,
        blockStyle.tableRows.length * rowHeight + 8.0,
      );
      if (y + tableHeight > size.height + .1 && fragments.isNotEmpty) {
        flush();
      }
      addBlockFragment(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: Rect.fromLTWH(0, y, blockWidth, tableHeight),
          blockStyle: blockStyle,
          isLeadingHeading: isLeadingHeading,
        ),
      );
      y += tableHeight;
      return true;
    }

    final imageUrl = readerIllustrationUrl(text);
    if (blockStyle?.imageGallery == index && imageUrl != null) {
      // One publisher album owns one leaf; its source images/captions keep
      // their original paragraph coordinates and remain available to links.
      final top = math.min(y, size.height * .3);
      flush();
      final width = math.max(1.0, blockWidth - readerPublisherImageGutter * 2);
      final footer = math.min(size.height * .25, font * 2.5 + 24);
      final natural = localImageSizes[imageUrl] ?? const Size(2, 3);
      final height = math.min(
        width / natural.aspectRatio + footer,
        math.max(1.0, size.height - top),
      );
      addBlockFragment(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: Rect.fromLTWH((blockWidth - width) / 2, top, width, height),
          image: true,
          blockStyle: blockStyle,
        ),
      );
      // The widget fits each image inside this stable frame, with a caption
      // and dots. Size stays independent of which image is currently selected.
      y = size.height;
      flush();
      return true;
    }
    final hasFollowingCaption =
        !isLeadingHeading &&
        index + 1 < content.paragraphs.length &&
        epubLayout?.blocks[index + 1]?.kind == EpubBlockKind.figcaption &&
        !(content.formats[index + 1]?.breakBefore ?? false) &&
        !(epubLayout?.blocks[index + 1]?.pageBreakBefore ?? false);
    final captionReserve = hasFollowingCaption
        ? math.max(font * 2.5, 48.0)
        : 0.0;
    final isFullPageImage =
        (blockStyle?.fullPage ?? false) && !hasFollowingCaption;
    if (imageUrl?.startsWith('wenku-local:') == true &&
        localImageSizes.containsKey(imageUrl)) {
      if (!vertical &&
          hasFollowingCaption &&
          fragments.isNotEmpty &&
          ((content.formats[index + 1]?.breakAfter ?? false) ||
              (epubLayout?.blocks[index + 1]?.pageBreakAfter ?? false) ||
              y + font * 6 + captionReserve > size.height)) {
        flush();
      }
      final authoredImageTop =
          !vertical && (blockStyle?.relativeInsets['margin-top'] ?? 0) > 0;
      final availHeight = !vertical && (hasFollowingCaption || authoredImageTop)
          ? math.max(font * 3, size.height - y - captionReserve)
          : size.height;
      final isRightFloat =
          !vertical &&
          blockStyle?.floatRightWidthFraction != null &&
          !hasFollowingCaption;
      final availWidth = isRightFloat
          ? blockWidth * blockStyle!.floatRightWidthFraction!
          : blockWidth;
      final Size imageSize;
      var sideBySideWidth = blockWidth;
      if (blockStyle != null && blockStyle.sideBySideImageUrls.length >= 2) {
        final sideUrls = blockStyle.sideBySideImageUrls;
        sideBySideWidth = math.max(
          16.0,
          blockWidth - readerPublisherImageGutter * 2,
        );
        final cellWidth = math.max(
          16.0,
          (sideBySideWidth -
                  readerPublisherImageCellGap * (sideUrls.length - 1)) /
              sideUrls.length,
        );
        var maxCellHeight = 0.0;
        for (final u in sideUrls) {
          final nat = localImageSizes[u] ?? localImageSizes[imageUrl]!;
          final cellSize = const LocalImageLayout().resolve(
            natural: nat,
            available: Size(cellWidth, availHeight),
            fontSize: font,
          );
          if (cellSize.height > maxCellHeight) {
            maxCellHeight = cellSize.height;
          }
        }
        imageSize = Size(sideBySideWidth, maxCellHeight);
      } else {
        final natural = localImageSizes[imageUrl]!;
        imageSize = LocalImageLayout.fromParagraph(text).resolve(
          natural: natural,
          available: Size(availWidth, availHeight),
          fontSize: font,
        );
      }
      if (isFullPageImage) {
        flush();
        addBlockFragment(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: Rect.fromLTWH(
              (blockWidth - imageSize.width) / 2,
              math.max(0.0, (size.height - imageSize.height) / 2),
              imageSize.width,
              imageSize.height,
            ),
            image: true,
            blockStyle: blockStyle,
          ),
        );
        flush();
        return true;
      }
      if (!vertical) {
        if (isRightFloat) {
          if (y + imageSize.height > size.height && fragments.isNotEmpty) {
            flush();
          }
          addBlockFragment(
            ReaderPageFragment(
              paragraph: index,
              start: 0,
              end: text.length,
              text: text,
              rect: Rect.fromLTWH(
                blockWidth - imageSize.width,
                y,
                imageSize.width,
                imageSize.height,
              ),
              image: true,
              blockStyle: blockStyle,
            ),
          );
          floatBottom = y + imageSize.height;
          floatWidth = imageSize.width + font * 0.25;
          firstFloatParagraph = true;
          return true;
        }
        if (y + imageSize.height + captionReserve > size.height + .1 &&
            fragments.isNotEmpty) {
          flush();
        }
        addBlockFragment(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: Rect.fromLTWH(
              blockStyle != null && blockStyle.sideBySideImageUrls.length >= 2
                  ? (blockWidth - sideBySideWidth) / 2
                  : switch (format.alignment) {
                      'left' || 'start' => 0,
                      'right' || 'end' => blockWidth - imageSize.width,
                      _ => (blockWidth - imageSize.width) / 2,
                    },
              y,
              imageSize.width,
              imageSize.height,
            ),
            image: true,
            blockStyle: blockStyle,
          ),
        );
        y += imageSize.height;
      } else {
        final width = math.max(
          math.min(columnWidth, blockWidth),
          imageSize.width,
        );
        if (right < width - .1 && fragments.isNotEmpty) flush();
        addBlockFragment(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: Rect.fromLTWH(
              right - width + (width - imageSize.width) / 2,
              0,
              imageSize.width,
              imageSize.height,
            ),
            image: true,
            blockStyle: blockStyle,
          ),
        );
        right -= width;
      }
      return true;
    }
    if (imageUrl != null || text.trim() == '[插图]') {
      flush();
      if (!vertical && hasFollowingCaption) {
        final imgH = math.max(font * 4, size.height - captionReserve);
        addBlockFragment(
          ReaderPageFragment(
            paragraph: index,
            start: 0,
            end: text.length,
            text: text,
            rect: Rect.fromLTWH(0, 0, blockWidth, imgH),
            image: true,
            blockStyle: blockStyle,
          ),
        );
        y = imgH;
        return true;
      }
      addBlockFragment(
        ReaderPageFragment(
          paragraph: index,
          start: 0,
          end: text.length,
          text: text,
          rect: Offset.zero & size,
          image: true,
          blockStyle: blockStyle,
        ),
      );
      flush();
      return true;
    }
    if (text.isEmpty) return true;

    final cacheKey = isLeadingHeading ? -1 : index;
    if (!vertical) {
      final hasRich =
          blockStyle != null ||
          paragraphSpans.isNotEmpty ||
          epubLayout != null;
      final indentEm = blockStyle != null
          ? blockStyle.effectiveIndent(preferences.indent)
          : (preferences.indent && format.allowsIndent ? 2.0 : 0.0);
      final indent = indentEm > 0;
      final prefix = indent ? readerIndentPlaceholder : '';
      final display = '$prefix$text';
      final floatTextWidth = y < floatBottom
          ? math.max(font * 4, blockWidth - floatWidth)
          : blockWidth;
      var metrics = floatTextWidth == blockWidth
          ? measured.horizontal[cacheKey]
          : null;
      final baseFont = style.fontSize ?? 19.0;
      final topExtra = epubBlockTopExtra(
        blockStyle,
        baseFont,
        width: floatTextWidth,
      );
      final bottomExtra = epubBlockBottomExtra(
        blockStyle,
        baseFont,
        width: floatTextWidth,
      );

      if (metrics == null) {
        if (cache != null && !isLeadingHeading) cache.paragraphMeasurements++;
        if (!hasRich) {
          final paragraphStyle = format.textStyle(style);
          final span = readerParagraphSpan(
            children: format.spans(text),
            style: paragraphStyle,
            indent: indent,
          );
          final builder = ui.ParagraphBuilder(
            paragraphStyle.getParagraphStyle(
              textDirection: TextDirection.ltr,
              textAlign: format.textAlign(
                preferences.justify ? TextAlign.justify : TextAlign.start,
              ),
              textScaler: scaler,
            ),
          );
          span.build(
            builder,
            textScaler: scaler,
            dimensions: readerIndentDimensions(indent, font),
          );
          final paragraph = builder.build();
          try {
            paragraph.layout(ui.ParagraphConstraints(width: floatTextWidth));
            final lines = paragraph.computeLineMetrics();
            final starts = <int>[0];
            // getLineBoundary copies the whole native line-metrics vector on
            // every query. Search the native logical line index instead: this
            // also handles bidi text and oversized graphemes without a visual
            // left-edge hit being mistaken for a source-text boundary.
            for (var line = 1; line < lines.length; line++) {
              var low = starts.last, high = display.length;
              while (low < high) {
                final middle = (low + high) ~/ 2;
                final at = paragraph.getLineNumberAt(middle);
                if (at != null && at < line) {
                  low = middle + 1;
                } else {
                  high = middle;
                }
              }
              starts.add(low);
              if (clock.elapsedMilliseconds >= 4) {
                await Future<void>.delayed(Duration.zero);
                if (!current()) return false;
                clock.reset();
              }
            }
            starts.add(display.length);
            metrics = _HorizontalMetrics(lines, starts);
            if (floatTextWidth == blockWidth) {
              measured.horizontal[cacheKey] = metrics;
            }
          } finally {
            paragraph.dispose();
          }
        } else {
          final resolvedStyle = resolveEpubBlockTextStyle(
            baseStyle: format.textStyle(style),
            blockStyle: blockStyle,
            bookId: bookId,
            epubLayout: epubLayout,
            userSelectedCustomFont: userSelectedCustomFont,
          );
          final scaledBlockFont = scaler.scale(
            resolvedStyle.fontSize ?? baseFont,
          );
          final align = blockStyle != null
              ? blockStyle.effectiveAlign(preferences.justify)
              : format.textAlign(
                  preferences.justify ? TextAlign.justify : TextAlign.start,
                );
          painter.textAlign = align;
          final built = buildRichParagraphSpans(
            text: text,
            style: resolvedStyle,
            indent: indent,
            indentEm: indentEm,
            scaledFontSize: scaledBlockFont,
            spans: paragraphSpans,
            footnotes: epubLayout?.footnotes ?? const {},
            embeddedFonts: epubLayout?.embeddedFonts ?? const {},
            bookId: bookId,
            localImageSizes: localImageSizes,
            forMeasurement: true,
          );
          painter.text = built.span;
          painter.setPlaceholderDimensions(built.dimensions);
          final inset = epubBlockHorizontalInset(
            blockStyle,
            baseFont,
            width: floatTextWidth,
          );
          painter.layout(maxWidth: math.max(font * 4, floatTextWidth - inset));
          final lines = painter.computeLineMetrics();
          final starts = <int>[0];
          for (var line = 1; line < lines.length; line++) {
            var low = starts.last, high = display.length;
            while (low < high) {
              final middle = (low + high) ~/ 2;
              final at = painter.getLineBoundary(TextPosition(offset: middle));
              if (at.end <= starts.last ||
                  painter
                          .getOffsetForCaret(
                            TextPosition(offset: middle),
                            Rect.zero,
                          )
                          .dy <
                      lines[line].baseline - lines[line].ascent - 0.5) {
                low = middle + 1;
              } else {
                high = middle;
              }
            }
            starts.add(low);
            if (clock.elapsedMilliseconds >= 4) {
              await Future<void>.delayed(Duration.zero);
              if (!current()) return false;
              clock.reset();
            }
          }
          starts.add(display.length);
          metrics = _HorizontalMetrics(lines, starts);
          if (floatTextWidth == blockWidth) {
            measured.horizontal[cacheKey] = metrics;
          }
        }
      }
      final heights = metrics.heights, starts = metrics.starts;
      // A typography change can move the source anchor into the middle of
      // a newly shaped line. Keep that line at top, rather than silently
      // ignoring the break and jumping back an entire page.
      var breakLine = -1;
      if (!isLeadingHeading && pageBreak?.paragraph == index) {
        final target = pageBreak!.offset + prefix.length;
        var low = 0, high = heights.length;
        while (low < high) {
          final middle = (low + high) ~/ 2;
          if (starts[middle] <= target) {
            low = middle + 1;
          } else {
            high = middle;
          }
        }
        breakLine = (low - 1).clamp(0, heights.length - 1);
      }
      var line = 0;
      while (line < heights.length) {
        if (line == breakLine) flush();
        final firstExtra = line == 0 ? topExtra : 0.0;
        final singleLineBottom = line == heights.length - 1 ? bottomExtra : 0.0;
        if (y + firstExtra + heights[line] + singleLineBottom >
                size.height + .1 &&
            fragments.isNotEmpty) {
          flush();
        }
        final first = line;
        var height = first == 0 ? topExtra : 0.0;
        while (line < heights.length &&
            (line == first || line != breakLine)) {
          final isLastLine = line == heights.length - 1;
          final nextAdd = heights[line] + (isLastLine ? bottomExtra : 0.0);
          if (line > first && y + height + nextAdd > size.height + .1) {
            break;
          }
          height += nextAdd;
          line++;
        }
        final start = (starts[first] - prefix.length).clamp(0, text.length);
        final end = (starts[line] - prefix.length).clamp(start, text.length);
        final isFirstOfBlock = first == 0;
        final isLastOfBlock = line == heights.length;
        if (end > start) {
          addBlockFragment(
            ReaderPageFragment(
              paragraph: index,
              start: start,
              end: end,
              text: text.substring(start, end),
              rect: Rect.fromLTWH(0, y, floatTextWidth, height),
              indent: start == 0 && indent,
              indentEm: indentEm,
              lineMetrics: ReaderFragmentLines._(
                metrics,
                first,
                line,
                prefix.length,
                text.length,
              ),
              blockStyle: blockStyle,
              spans: sliceEpubSpans(paragraphSpans, start, end),
              isLeadingHeading: isLeadingHeading,
              isFirstOfBlock: isFirstOfBlock,
              isLastOfBlock: isLastOfBlock,
            ),
          );
          y += height;
        }
        if (line < heights.length) flush();
      }
    } else {
      final blockScale = blockStyle?.effectiveScale ?? 1.0;
      final pFont = font * blockScale;
      final hasRuby =
          format.ruby.isNotEmpty ||
          paragraphSpans.any((s) => s.rubyText != null);
      final paragraphColumnWidth = hasRuby
          ? math.max(columnWidth * blockScale, pFont * 1.6)
          : columnWidth * math.max(1.0, blockScale * 0.92);
      final indentEm = blockStyle != null
          ? blockStyle.effectiveIndent(preferences.indent)
          : (preferences.indent && format.allowsIndent ? 2.0 : 0.0);
      var metrics = measured.vertical[cacheKey];
      if (metrics == null) {
        if (cache != null && !isLeadingHeading) cache.paragraphMeasurements++;
        // Simple characters already use the runtime's single-character
        // strings. Share only complex graphemes, within this layout cache.
        final clusters = text.characters
            .map(
              (cluster) => cluster.length == 1
                  ? cluster
                  : measured.complexGraphemes.putIfAbsent(
                      cluster,
                      () => cluster,
                    ),
            )
            .toList(growable: false);
        final offsets = Uint32List(clusters.length + 1);
        final advances = List<double>.filled(clusters.length, 0);
        final rotations = List<double>.filled(clusters.length, 0);
        final annotations =
            format.emphasis.isEmpty &&
                format.ruby.isEmpty &&
                format.references.isEmpty
            ? null
            : ReaderRichParagraphIndex(format);
        painter.textScaler = TextScaler.noScaling;
        var c = 0;
        for (final cluster in clusters) {
          offsets[c + 1] = offsets[c] + cluster.length;
          var spanScale = 1.0;
          if (paragraphSpans.isNotEmpty) {
            final cStart = offsets[c], cEnd = offsets[c + 1];
            for (final s in paragraphSpans) {
              if (s.start < cEnd && s.end > cStart) {
                spanScale =
                    (s.fontScale ?? 1.0) *
                    (s.superscript || s.subscript || s.footnoteId != null
                        ? 0.78
                        : 1.0);
                break;
              }
            }
          }
          final effectiveScale = blockScale * spanScale;
          final emphasis = annotations?.emphasisAt(offsets[c]) ?? 0;
          final metric = glyphMetrics.putIfAbsent((cluster, emphasis), () {
            final display = _verticalCluster(cluster);
            final rotation = RotationRules.getRotationAngle(
              display,
              CharacterClassifier.classify(display),
              latinOrientation == ReaderVerticalLatinOrientation.rotated,
            );
            if (rotation == 0) {
              return (
                advance:
                    font + 1 + scaler.scale(preferences.letterSpacing - .1),
                rotation: rotation,
              );
            }
            painter.text = TextSpan(
              text: display,
              style: ReaderRichParagraph.emphasized(verticalStyle, emphasis),
            );
            painter.layout();
            return (
              advance:
                  painter.width +
                  1 +
                  scaler.scale(preferences.letterSpacing - .1),
              rotation: rotation,
            );
          });
          rotations[c] = metric.rotation;
          advances[c] = (effectiveScale - 1.0).abs() < 0.01
              ? metric.advance
              : metric.advance * effectiveScale;
          c++;
          if (c % 128 == 0 && clock.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            if (!current()) return false;
            clock.reset();
          }
        }
        metrics = measured.vertical[cacheKey] = _VerticalMetrics(
          clusters,
          offsets,
          advances,
          rotations,
          annotations,
        );
      }
      final clusters = metrics.clusters, offsets = metrics.offsets;
      final advances = metrics.advances;
      var first = 0;
      final breakCluster = !isLeadingHeading && pageBreak?.paragraph == index
          ? offsets.indexOf(pageBreak!.offset)
          : -1;
      final resolvedFamily = blockStyle?.fontFamily != null
          ? (EpubFontManager.resolveFontFamily(
                  bookId,
                  blockStyle!.fontFamily,
                  epubLayout?.embeddedFonts ?? const {},
                ) ??
                blockStyle.fontFamily)
          : null;
      while (first < clusters.length) {
        if (first == breakCluster) flush();
        if (right < paragraphColumnWidth - .1 && fragments.isNotEmpty) {
          flush();
        }
        final indent = first == 0 && indentEm > 0 ? pFont * indentEm : 0.0;
        var height = indent;
        var end = first;
        while (end < clusters.length &&
            (end == first || end != breakCluster) &&
            (end == first || height + advances[end] <= size.height)) {
          if (clusters[end] == '\n') {
            end++;
            break;
          }
          height += advances[end++];
        }
        // Backtrack on grapheme boundaries. Never split emoji/combining text.
        if (end < clusters.length &&
            end != breakCluster &&
            clusters[end - 1] != '\n') {
          var adjusted = end;
          while (adjusted > first + 1 &&
              !_canBreakVertical(
                clusters[adjusted - 1],
                clusters[adjusted],
              )) {
            adjusted--;
          }
          end = adjusted;
        }
        final sourceStart = offsets[first], sourceEnd = offsets[end];
        if (previousParagraph != -1 && previousParagraph != cacheKey) {
          pageText.write('\n\n');
        }
        final pageStart = pageText.length;
        pageText.write(text.substring(sourceStart, sourceEnd));
        previousParagraph = cacheKey;
        final width = math.min(paragraphColumnWidth, blockWidth);
        final left = right - width;
        final used = advances
            .getRange(first, end)
            .fold(0.0, (sum, value) => sum + value);
        final align = blockStyle?.align;
        final alignmentOffset = align != null
            ? (first == 0 &&
                      end == clusters.length &&
                      indent == 0 &&
                      (align == TextAlign.center ||
                          align == TextAlign.end ||
                          align == TextAlign.right)
                  ? align == TextAlign.center
                        ? math.max(0.0, (size.height - used) / 2)
                        : math.max(0.0, size.height - used)
                  : 0.0)
            : switch (format.alignment) {
                'right' || 'end' => math.max(0.0, size.height - indent - used),
                'center' => math.max(0.0, size.height - indent - used) / 2,
                _ => 0.0,
              };
        final extra =
            alignmentOffset == 0 &&
                format.textAlign(
                      preferences.justify
                          ? TextAlign.justify
                          : TextAlign.start,
                    ) ==
                    TextAlign.justify &&
                end < clusters.length &&
                end - first > 1 &&
                clusters[end - 1] != '\n'
            ? math.max(0.0, (size.height - indent - used) / (end - first - 1))
            : 0.0;
        var glyphY = indent + alignmentOffset;
        for (var c = first; c < end; c++) {
          if (clusters[c] == '\n') continue;
          glyphY += advances[c] + extra;
        }
        columns.add(
          _VerticalColumn(
            metrics: metrics,
            paragraph: index,
            first: first,
            end: end,
            pageStart: pageStart,
            left:
                left +
                (width - pFont - (hasRuby ? pFont * .52 : 0)) / 2,
            indent: indent + alignmentOffset,
            font: pFont,
            extra: extra,
            format: format,
            blockStyle: blockStyle,
            paragraphSpans: paragraphSpans,
            blockScale: blockScale,
            resolvedFamily: resolvedFamily,
            isLeadingHeading: isLeadingHeading,
          ),
        );
        addBlockFragment(
          ReaderPageFragment(
            paragraph: index,
            start: sourceStart,
            end: sourceEnd,
            text: text.substring(sourceStart, sourceEnd),
            rect: Rect.fromLTWH(left, 0, width, glyphY - extra),
            blockStyle: blockStyle,
            spans: sliceEpubSpans(paragraphSpans, sourceStart, sourceEnd),
            isLeadingHeading: isLeadingHeading,
            isFirstOfBlock: first == 0,
            isLastOfBlock: end == clusters.length,
          ),
        );
        right -= width;
        first = end;
        if (clock.elapsedMilliseconds >= 4) {
          await Future<void>.delayed(Duration.zero);
          if (!current()) return false;
          clock.reset();
        }
      }
      painter.textScaler = scaler;
    }
    if (clock.elapsedMilliseconds >= 4) {
      await Future<void>.delayed(Duration.zero);
      clock.reset();
    }
    return true;
  }

  try {
    final leading = epubLayout?.leadingHeading;
    var placedLeading = leading == null || leading.text.isEmpty;
    Future<bool> emitLeading(int targetIndex) => layoutBlock(
      index: targetIndex,
      text: leading!.text,
      format: ReaderRichParagraph(
        spacing: ReaderBlockSpacing(
          before: leading.style.marginTopEm > 0
              ? ['${leading.style.marginTopEm}em']
              : const [],
          after: leading.style.marginBottomEm > 0
              ? ['${leading.style.marginBottomEm}em']
              : const ['0.5em'],
        ),
      ),
      blockStyle: leading.style,
      paragraphSpans: leading.spans,
      isLeadingHeading: true,
    );

    for (final index in content.order) {
      final text = content.paragraphs[index];
      final format = content.formats[index] ?? const ReaderRichParagraph();
      final blockStyle = epubLayout?.blocks[index];
      if (blockStyle?.imageGallery != null &&
          blockStyle!.imageGallery != index) {
        continue;
      }
      final paragraphSpans = epubLayout?.spans[index] ?? const [];
      if (!placedLeading &&
          !(blockStyle?.kind == EpubBlockKind.fullPageImage &&
              readerIllustrationUrl(text) != null)) {
        placedLeading = true;
        final okLead = await emitLeading(index);
        if (!okLead) return null;
      }
      final ok = await layoutBlock(
        index: index,
        text: text,
        format: format,
        blockStyle: blockStyle,
        paragraphSpans: paragraphSpans,
        isLeadingHeading: false,
      );
      if (!ok) return null;
    }
    if (!placedLeading) {
      placedLeading = true;
      final okLead = await emitLeading(0);
      if (!okLead) return null;
    }
    flush();
    if (pages.isEmpty) pages.add(ReaderLeaf(const []));
    return current()
        ? ReaderPagination._measured(List.unmodifiable(pages), size, glyphCache)
        : null;
  } finally {
    painter.dispose();
  }
}

bool _canBreakVertical(String before, String after) {
  const closing = '，。！？、；：）》」』】〕］｝’”';
  const opening = '（《「『【〔［｛‘“';
  return !closing.contains(after) &&
      !opening.contains(before) &&
      KinsokuProcessor.canBreakAt('$before$after', before.length);
}
