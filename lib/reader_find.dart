import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'reader_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'app_search_field.dart';
import 'epub_rich_layout.dart';
import 'reader_content.dart';
import 'reader_rich_content.dart';
import 'reader_annotations.dart';
import 'reader_underline.dart';
import 'reader_mark_style.dart';

class ReaderMatch {
  const ReaderMatch(this.paragraph, this.start, this.end, {this.chapter});
  final int paragraph;
  final int start;
  final int end;
  final int? chapter;
}

class ReaderFindResult {
  const ReaderFindResult(this.matches, {this.truncated = false});
  final List<ReaderMatch> matches;
  final bool truncated;
}

ReaderFindResult _searchParagraphs(
  ({List<String> paragraphs, String query}) input,
) {
  final pattern = RegExp(
    RegExp.escape(input.query),
    caseSensitive: false,
    unicode: true,
  );
  final matches = <ReaderMatch>[];
  for (var index = 0; index < input.paragraphs.length; index++) {
    if (readerIllustrationUrl(input.paragraphs[index]) != null) continue;
    for (final match in pattern.allMatches(input.paragraphs[index])) {
      if (matches.length == 500) {
        return ReaderFindResult(List.unmodifiable(matches), truncated: true);
      }
      matches.add(ReaderMatch(index, match.start, match.end));
    }
  }
  return ReaderFindResult(List.unmodifiable(matches));
}

Future<ReaderFindResult> findInReader(
  ReaderContent content,
  String query,
) async {
  final term = query.trim();
  if (term.isEmpty || term.length > 120) return const ReaderFindResult([]);
  final input = (paragraphs: content.paragraphs, query: term);
  final length = content.paragraphs.fold<int>(
    0,
    (sum, text) => sum + text.length,
  );
  return length > 64 * 1024
      ? compute(_searchParagraphs, input)
      : _searchParagraphs(input);
}

class ReaderFindPanel extends StatefulWidget {
  const ReaderFindPanel({
    super.key,
    required this.content,
    this.onBookSearch,
    this.embedded = false,
  });
  final ReaderContent content;
  final VoidCallback? onBookSearch;
  final bool embedded;
  @override
  State<ReaderFindPanel> createState() => _ReaderFindPanelState();
}

class _ReaderFindPanelState extends State<ReaderFindPanel> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  bool _searching = false;
  ReaderFindResult _result = const ReaderFindResult([]);

  @override
  void initState() {
    super.initState();
    _query.addListener(_edited);
  }

  void _edited() {
    _debounce?.cancel();
    _generation++;
    if (!_query.value.composing.isCollapsed) return;
    if (_query.text.trim().isEmpty) {
      setState(() {
        _searching = false;
        _result = const ReaderFindResult([]);
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 180), _search);
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final generation = ++_generation;
    final result = await findInReader(widget.content, _query.text);
    if (mounted && generation == _generation) {
      setState(() {
        _result = result;
        _searching = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: math.min(520, MediaQuery.sizeOf(context).height * .64),
    child: CustomScrollView(
      key: const ValueKey('reader-find-scroll'),
      primary: false,
      slivers: [
        if (!widget.embedded)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 8, 14, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  const Expanded(
                    child: ArchiveSection(
                      title: '章内查找',
                      code: 'READER / TEXT QUERY',
                    ),
                  ),
                  if (widget.onBookSearch != null)
                    GlassTextButton(
                      onPressed: widget.onBookSearch,
                      child: const AppText('整书查找'),
                    ),
                  GlassIconButton(
                    icon: CupertinoIcons.xmark,
                    label: '关闭章内查找',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSearchField(
                  inputKey: const ValueKey('reader-find-field'),
                  controller: _query,
                  hint: '查找当前章节文字',
                  onSubmitted: (_) => _search(),
                ),
                const SizedBox(height: 12),
                Text(
                  _searching
                      ? '正在查找…'
                      : _query.text.trim().isEmpty
                      ? '仅查找已加载的本章正文，点按结果跳到原文。'
                      : _query.text.trim().length > 120
                      ? '查找文字请控制在 120 字以内'
                      : _result.matches.isEmpty
                      ? '本章没有匹配文字'
                      : _result.truncated
                      ? '显示前 500 处匹配，请缩短查找范围'
                      : '${_result.matches.length} 处匹配',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!_searching)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            sliver: SliverList.builder(
              itemCount: _result.matches.length,
              itemBuilder: (context, index) {
                final match = _result.matches[index];
                final text = widget.content.paragraphs[match.paragraph];
                final start = math.max(0, match.start - 24);
                final end = math.min(text.length, match.end + 56);
                return JellyTapSurface(
                  key: ValueKey('reader-find-result-$index'),
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    Navigator.pop(context, match);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第 ${match.paragraph + 1} 段 · ${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    '${start > 0 ? '…' : ''}${text.substring(start, match.start)}',
                              ),
                              TextSpan(
                                text: text.substring(match.start, match.end),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text:
                                    '${text.substring(match.end, end)}${end < text.length ? '…' : ''}',
                              ),
                            ],
                          ),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
}

/// Updating a match touches only the currently materialized lazy paragraphs.
/// Background tint changes no font metrics, line breaks, or glow/shadow layers.
class ReaderHighlightText extends StatelessWidget {
  const ReaderHighlightText({
    super.key,
    required this.index,
    required this.text,
    required this.match,
    required this.style,
    this.indent = false,
    this.indentEm = 2.0,
    this.textAlign = TextAlign.start,
    this.sourceStart = 0,
    this.format,
    this.onNote,
    this.chapter,
    this.underlineChanges,
    this.underlines,
    this.annotations,
    this.continuesParagraph = false,
    this.blockStyle,
    this.spans = const [],
    this.bookId,
    this.epubLayout,
    this.userSelectedCustomFont = false,
    this.paperColor,
    this.onPaperColor,
    this.accentColor,
    this.localImageSizes = const {},
    this.onTapFootnote,
  });
  final int index;
  final int? chapter;
  final String text;
  final ValueListenable<ReaderMatch?> match;
  final TextStyle style;
  final bool indent;
  final double indentEm;
  final TextAlign textAlign;
  final int sourceStart;
  final ReaderRichParagraph? format;
  final ValueChanged<String>? onNote;
  final Listenable? underlineChanges;
  final List<TextRange> Function()? underlines;
  final List<ReaderTextMark> Function()? annotations;
  final EpubBlockStyle? blockStyle;
  final List<EpubInlineSpan> spans;
  final int? bookId;
  final EpubChapterLayout? epubLayout;
  final bool userSelectedCustomFont;
  final Color? paperColor;
  final Color? onPaperColor;
  final Color? accentColor;
  final Map<String, Size> localImageSizes;
  final ValueChanged<EpubFootnote>? onTapFootnote;

  /// A paginated slice ends before its source paragraph's real final line.
  final bool continuesParagraph;
  ReaderRichParagraph? _effectiveAnnotationFormat() {
    final extraRuby = <ReaderRuby>[];
    final extraRefs = <ReaderNoteReference>[];
    for (final s in spans) {
      if (s.inlineImageUrl != null) continue;
      final start = s.start.clamp(0, text.length);
      final end = s.end.clamp(start, text.length);
      if (end <= start) continue;
      if (s.rubyText != null && s.rubyText!.isNotEmpty) {
        extraRuby.add(ReaderRuby(start, end, s.rubyText!));
      }
      if (s.footnoteId != null && s.footnoteId!.isNotEmpty) {
        extraRefs.add(ReaderNoteReference(start, end, s.footnoteId!));
      }
    }
    if (format == null) {
      if (extraRuby.isEmpty && extraRefs.isEmpty) return null;
      return ReaderRichParagraph(ruby: extraRuby, references: extraRefs);
    }
    if (extraRuby.isEmpty && extraRefs.isEmpty) return format;
    return ReaderRichParagraph(
      alignment: format!.alignment,
      writing: format!.writing,
      rule: format!.rule,
      ruby: format!.ruby.isNotEmpty ? format!.ruby : extraRuby,
      references:
          format!.references.isNotEmpty ? format!.references : extraRefs,
      emphasis: format!.emphasis,
      breakBefore: format!.breakBefore,
      breakAfter: format!.breakAfter,
      spacing: format!.spacing,
      language: format!.language,
      opacity: format!.opacity,
    );
  }

  Widget _annotate(
    BuildContext context,
    Widget child,
    TextStyle resolvedStyle,
  ) {
    final effectiveFormat = _effectiveAnnotationFormat();
    if (effectiveFormat == null &&
        !spans.any((span) => span.underlineOffsetEm != null)) {
      return child;
    }
    return ReaderAnnotations(
      format: effectiveFormat ?? const ReaderRichParagraph(),
      epubSpans: spans,
      paperColor: paperColor ?? const Color(0xFFFDFBF7),
      style: DefaultTextStyle.of(context).style.merge(resolvedStyle),
      scaler: MediaQuery.textScalerOf(context),
      prefix: indent && indentEm > 0 ? readerIndentLength : 0,
      onNote: (id) {
        final footnote = epubLayout?.footnotes[id];
        if (footnote != null && onTapFootnote != null) {
          onTapFootnote!(footnote);
          return;
        }
        onNote?.call(id);
      },
      child: child,
    );
  }

  TextAlign _effectiveAlign() =>
      blockStyle?.align ?? format?.textAlign(textAlign) ?? textAlign;

  Widget _paragraph(
    BuildContext context,
    List<InlineSpan> children,
    TextStyle effectiveStyle,
  ) {
    final alignment = _effectiveAlign();
    Widget text({double? continuationWidth}) => Text.rich(
      readerParagraphSpan(
        children: children,
        style: effectiveStyle,
        indent: indent,
        indentEm: indentEm,
        continuationWidth: continuationWidth,
      ),
      key: ValueKey('paragraph-$index'),
      style: effectiveStyle,
      textAlign: alignment,
      overflow: continuesParagraph && alignment == TextAlign.justify
          ? TextOverflow.clip
          : null,
    );
    return _annotate(
      context,
      continuesParagraph && alignment == TextAlign.justify
          ? LayoutBuilder(
              builder: (context, constraints) =>
                  text(continuationWidth: constraints.maxWidth),
            )
          : text(),
      effectiveStyle,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([match, ?underlineChanges]),
    builder: (context, _) {
      final baseStyle = format?.textStyle(style) ?? style;
      final effectiveStyle = resolveEpubBlockTextStyle(
        baseStyle: baseStyle,
        blockStyle: blockStyle,
        bookId: bookId,
        epubLayout: epubLayout,
        userSelectedCustomFont: userSelectedCustomFont,
        paperColor: paperColor,
        onPaperColor: onPaperColor,
      );
      final selected = match.value;
      final marked =
          (annotations?.call() ??
                  [
                    for (final range
                        in underlines?.call() ?? const <TextRange>[])
                      ReaderTextMark(
                        range.start,
                        range.end,
                        ReaderMarkStyle.underline,
                        ReaderMarkColor.ink,
                      ),
                  ])
              .where((mark) => mark.style != ReaderMarkStyle.none)
              .toList();
      final matching =
          selected != null &&
          (selected.chapter == null ||
              chapter == null ||
              selected.chapter == chapter) &&
          selected.paragraph == index &&
          selected.end > sourceStart &&
          selected.start < sourceStart + text.length;
      if (spans.isNotEmpty && marked.isEmpty) {
        final alignment = _effectiveAlign();
        final highlight = matching
            ? (
                start: (selected.start - sourceStart).clamp(0, text.length),
                end: (selected.end - sourceStart).clamp(
                  (selected.start - sourceStart).clamp(0, text.length),
                  text.length,
                ),
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .14),
              )
            : null;
        Widget richText({double? continuationWidth}) {
          final built = buildRichParagraphSpans(
            text: text,
            style: effectiveStyle,
            indent: indent,
            indentEm: indentEm,
            continuationWidth: continuationWidth,
            spans: spans,
            footnotes: epubLayout?.footnotes ?? const {},
            embeddedFonts: epubLayout?.embeddedFonts ?? const {},
            bookId: bookId,
            localImageSizes: localImageSizes,
            paperColor: paperColor,
            onPaperColor: onPaperColor,
            accentColor: accentColor,
            highlight: highlight,
            onTapFootnote: onTapFootnote,
          );
          return Text.rich(
            built.span,
            key: ValueKey('paragraph-$index'),
            style: effectiveStyle,
            textAlign: alignment,
            overflow: continuesParagraph && alignment == TextAlign.justify
                ? TextOverflow.clip
                : null,
          );
        }

        return _annotate(
          context,
          continuesParagraph && alignment == TextAlign.justify
              ? LayoutBuilder(
                  builder: (context, constraints) =>
                      richText(continuationWidth: constraints.maxWidth),
                )
              : richText(),
          effectiveStyle,
        );
      }
      if (!matching && marked.isEmpty) {
        return _paragraph(
          context,
          format?.spans(text) ?? [TextSpan(text: text)],
          effectiveStyle,
        );
      }
      final matchStart = matching
          ? (selected.start - sourceStart).clamp(0, text.length)
          : 0;
      final matchEnd = matching
          ? (selected.end - sourceStart).clamp(matchStart, text.length)
          : 0;
      final points = <int>{
        0,
        text.length,
        if (matching) ...[matchStart, matchEnd],
      };
      for (final range in marked) {
        points.add(range.start.clamp(0, text.length));
        points.add(range.end.clamp(0, text.length));
      }
      final boundaries = points.toList()..sort();
      final inlineSpans = <InlineSpan>[];
      for (var i = 0; i + 1 < boundaries.length; i++) {
        final start = boundaries[i], end = boundaries[i + 1];
        if (end <= start) continue;
        final highlighted = matching && start < matchEnd && end > matchStart;
        final covering = marked.where(
          (range) => start < range.end && end > range.start,
        );
        final underline = covering
            .where((range) => range.style == ReaderMarkStyle.underline)
            .firstOrNull;
        final highlight = covering
            .where((range) => range.style == ReaderMarkStyle.highlight)
            .firstOrNull;
        final ink =
            effectiveStyle.color ?? Theme.of(context).colorScheme.onSurface;
        final dark = Theme.of(context).brightness == Brightness.dark;
        inlineSpans.add(
          TextSpan(
            children:
                format?.slice(start, end).spans(text.substring(start, end)) ??
                [TextSpan(text: text.substring(start, end))],
            style: TextStyle(
              backgroundColor: highlighted
                  ? Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .14)
                  : highlight == null
                  ? null
                  : readerMarkTint(highlight.color, ink, dark: dark),
              decoration: underline != null ? TextDecoration.underline : null,
              decorationColor: underline != null
                  ? readerMarkInk(underline.color, ink, dark: dark).withValues(
                      alpha: underline.color == ReaderMarkColor.ink ? .8 : .9,
                    )
                  : null,
              decorationThickness: underline != null ? 1.3 : null,
            ),
          ),
        );
      }
      final paragraph = _paragraph(context, inlineSpans, effectiveStyle);
      final outlines = marked
          .where((mark) => mark.style == ReaderMarkStyle.outline)
          .toList();
      return outlines.isEmpty
          ? paragraph
          : ReaderAnnotationOutlines(
              marks: outlines,
              foreground:
                  effectiveStyle.color ??
                  Theme.of(context).colorScheme.onSurface,
              dark: Theme.of(context).brightness == Brightness.dark,
              prefix: indent && indentEm > 0 ? readerIndentLength : 0,
              child: paragraph,
            );
    },
  );
}
