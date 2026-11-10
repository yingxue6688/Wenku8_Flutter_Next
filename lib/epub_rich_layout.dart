import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as ast;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as html;
import 'package:xml/xml.dart';

import 'local_image_layout.dart';

enum EpubBlockKind {
  paragraph,
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  blockquote,
  callout,
  pre,
  hr,
  listItem,
  figcaption,
  table,
  fullPageImage,
}

class EpubBlockStyle {
  const EpubBlockStyle({
    this.kind = EpubBlockKind.paragraph,
    this.fontScale,
    this.fontWeight,
    this.italic = false,
    this.fontFamily,
    this.textAlign,
    this.textIndentEm,
    this.lineHeight,
    this.letterSpacingEm,
    this.marginTopEm = 0,
    this.marginBottomEm = 0,
    this.blankLinesEm = 0,
    this.marginLeftEm = 0,
    this.marginRightEm = 0,
    this.paddingEm = 0,
    this.paddingTopEm = 0,
    this.paddingBottomEm = 0,
    this.separateVerticalPadding = false,
    this.lineBreakBefore = false,
    this.horizontalBleed = false,
    this.relativeInsets = const {},
    this.ruleHeightEm,
    this.textColor,
    this.backgroundColor,
    this.borderColor,
    this.borderLeftWidth = 0,
    this.borderWidth = 0,
    this.borderTopWidth = 0,
    this.borderBottomWidth = 0,
    this.borderStyle,
    this.borderRadius = 0,
    this.pageBreakBefore = false,
    this.pageBreakAfter = false,
    this.listMarker,
    this.tableRows = const [],
    this.caption,
    this.sideBySideImageUrls = const [],
    this.imageGallery,
    this.imageTapTargets = const [],
    this.floatRightWidthFraction,
  });

  final EpubBlockKind kind;
  final double? fontScale;
  final int? fontWeight;
  final bool italic;
  final String? fontFamily;
  final TextAlign? textAlign;
  final double? textIndentEm;
  final double? lineHeight;
  final double? letterSpacingEm;
  final double marginTopEm;
  final double marginBottomEm;
  final double blankLinesEm;
  final double marginLeftEm;
  final double marginRightEm;
  final double paddingEm;
  final double paddingTopEm;
  final double paddingBottomEm;
  // Parsed CSS has independent axes; horizontal container padding must not
  // become top/bottom padding on every child paragraph.
  final bool separateVerticalPadding;
  final bool lineBreakBefore;
  final bool horizontalBleed;
  // Percentage margins/padding use the containing block's width, including
  // vertical edges. Keep them separate from font-relative em lengths.
  final Map<String, double> relativeInsets;
  final double? ruleHeightEm;

  double inset(String edge, double em, double font, double width) =>
      em * font + (relativeInsets[edge] ?? 0) * width;
  final int? textColor;
  final int? backgroundColor;
  final int? borderColor;
  final double borderLeftWidth;
  final double borderWidth;
  final double borderTopWidth;
  final double borderBottomWidth;
  final String? borderStyle;
  final double borderRadius;
  final bool pageBreakBefore;
  final bool pageBreakAfter;
  final String? listMarker;
  final List<List<String>> tableRows;
  final String? caption;
  final List<String> sideBySideImageUrls;
  // Source paragraphs stay intact so image anchors and saved positions survive.
  // Every member points to the first image paragraph rendered as the album.
  final int? imageGallery;
  final List<String> imageTapTargets;
  final double? floatRightWidthFraction;

  TextAlign? get align => textAlign;
  double? get indentEm => textIndentEm;
  bool get fullPage =>
      kind == EpubBlockKind.fullPageImage ||
      (pageBreakBefore && pageBreakAfter);

  bool get isHeading =>
      kind.index >= EpubBlockKind.heading1.index &&
      kind.index <= EpubBlockKind.heading6.index;

  double get effectivePaddingTopEm =>
      paddingTopEm > 0 || separateVerticalPadding ? paddingTopEm : paddingEm;

  double get effectivePaddingBottomEm =>
      paddingBottomEm > 0 || separateVerticalPadding
      ? paddingBottomEm
      : paddingEm;

  bool get hasBoxDecoration =>
      kind == EpubBlockKind.blockquote ||
      kind == EpubBlockKind.callout ||
      kind == EpubBlockKind.pre ||
      backgroundColor != null ||
      borderLeftWidth > 0 ||
      borderWidth > 0 ||
      borderTopWidth > 0 ||
      borderBottomWidth > 0 ||
      paddingEm > 0 ||
      paddingTopEm > 0 ||
      paddingBottomEm > 0 ||
      relativeInsets.keys.any((key) => key.startsWith('padding-'));

  double get effectiveScale =>
      fontScale ??
      switch (kind) {
        EpubBlockKind.heading1 => 1.45,
        EpubBlockKind.heading2 => 1.30,
        EpubBlockKind.heading3 => 1.18,
        EpubBlockKind.heading4 => 1.08,
        EpubBlockKind.heading5 => 1.0,
        EpubBlockKind.heading6 => 0.94,
        EpubBlockKind.figcaption => 0.88,
        EpubBlockKind.blockquote => 0.96,
        EpubBlockKind.pre => 0.92,
        _ => 1.0,
      };

  FontWeight? get effectiveFontWeight {
    if (fontWeight != null) {
      return FontWeight.values[((fontWeight! ~/ 100) - 1).clamp(0, 8)];
    }
    if (isHeading) return FontWeight.w700;
    return null;
  }

  double effectiveIndent(bool userIndent) {
    if (textIndentEm != null) return textIndentEm!;
    if (isHeading ||
        kind == EpubBlockKind.hr ||
        kind == EpubBlockKind.table ||
        kind == EpubBlockKind.figcaption ||
        kind == EpubBlockKind.listItem ||
        kind == EpubBlockKind.pre ||
        textAlign == TextAlign.center ||
        textAlign == TextAlign.right ||
        textAlign == TextAlign.end) {
      return 0.0;
    }
    return userIndent ? 2.0 : 0.0;
  }

  TextAlign effectiveAlign(bool userJustify) {
    if (textAlign != null) return textAlign!;
    if (kind == EpubBlockKind.figcaption) return TextAlign.center;
    if (isHeading) return TextAlign.start;
    return userJustify ? TextAlign.justify : TextAlign.start;
  }

  EpubBlockStyle copyWith({
    EpubBlockKind? kind,
    double? fontScale,
    int? fontWeight,
    bool? italic,
    String? fontFamily,
    TextAlign? textAlign,
    double? textIndentEm,
    double? lineHeight,
    double? letterSpacingEm,
    double? marginTopEm,
    double? marginBottomEm,
    double? blankLinesEm,
    double? marginLeftEm,
    double? marginRightEm,
    double? paddingEm,
    double? paddingTopEm,
    double? paddingBottomEm,
    bool? separateVerticalPadding,
    bool? lineBreakBefore,
    bool? horizontalBleed,
    Map<String, double>? relativeInsets,
    double? ruleHeightEm,
    int? textColor,
    int? backgroundColor,
    int? borderColor,
    double? borderLeftWidth,
    double? borderWidth,
    double? borderTopWidth,
    double? borderBottomWidth,
    String? borderStyle,
    double? borderRadius,
    bool? pageBreakBefore,
    bool? pageBreakAfter,
    String? listMarker,
    List<List<String>>? tableRows,
    String? caption,
    List<String>? sideBySideImageUrls,
    int? imageGallery,
    List<String>? imageTapTargets,
    double? floatRightWidthFraction,
  }) => EpubBlockStyle(
    kind: kind ?? this.kind,
    fontScale: fontScale ?? this.fontScale,
    fontWeight: fontWeight ?? this.fontWeight,
    italic: italic ?? this.italic,
    fontFamily: fontFamily ?? this.fontFamily,
    textAlign: textAlign ?? this.textAlign,
    textIndentEm: textIndentEm ?? this.textIndentEm,
    lineHeight: lineHeight ?? this.lineHeight,
    letterSpacingEm: letterSpacingEm ?? this.letterSpacingEm,
    marginTopEm: marginTopEm ?? this.marginTopEm,
    marginBottomEm: marginBottomEm ?? this.marginBottomEm,
    blankLinesEm: blankLinesEm ?? this.blankLinesEm,
    marginLeftEm: marginLeftEm ?? this.marginLeftEm,
    marginRightEm: marginRightEm ?? this.marginRightEm,
    paddingEm: paddingEm ?? this.paddingEm,
    paddingTopEm: paddingTopEm ?? this.paddingTopEm,
    paddingBottomEm: paddingBottomEm ?? this.paddingBottomEm,
    separateVerticalPadding:
        separateVerticalPadding ?? this.separateVerticalPadding,
    lineBreakBefore: lineBreakBefore ?? this.lineBreakBefore,
    horizontalBleed: horizontalBleed ?? this.horizontalBleed,
    relativeInsets: relativeInsets ?? this.relativeInsets,
    ruleHeightEm: ruleHeightEm ?? this.ruleHeightEm,
    textColor: textColor ?? this.textColor,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    borderColor: borderColor ?? this.borderColor,
    borderLeftWidth: borderLeftWidth ?? this.borderLeftWidth,
    borderWidth: borderWidth ?? this.borderWidth,
    borderTopWidth: borderTopWidth ?? this.borderTopWidth,
    borderBottomWidth: borderBottomWidth ?? this.borderBottomWidth,
    borderStyle: borderStyle ?? this.borderStyle,
    borderRadius: borderRadius ?? this.borderRadius,
    pageBreakBefore: pageBreakBefore ?? this.pageBreakBefore,
    pageBreakAfter: pageBreakAfter ?? this.pageBreakAfter,
    listMarker: listMarker ?? this.listMarker,
    tableRows: tableRows ?? this.tableRows,
    caption: caption ?? this.caption,
    sideBySideImageUrls: sideBySideImageUrls ?? this.sideBySideImageUrls,
    imageGallery: imageGallery ?? this.imageGallery,
    imageTapTargets: imageTapTargets ?? this.imageTapTargets,
    floatRightWidthFraction:
        floatRightWidthFraction ?? this.floatRightWidthFraction,
  );

  Map<String, Object?> toJson() => {
    if (kind != EpubBlockKind.paragraph) 'k': kind.name,
    if (fontScale != null) 'fs': fontScale,
    if (fontWeight != null) 'fw': fontWeight,
    if (italic) 'it': true,
    if (fontFamily != null) 'ff': fontFamily,
    if (textAlign != null) 'ta': textAlign!.name,
    if (textIndentEm != null) 'ti': textIndentEm,
    if (lineHeight != null) 'lh': lineHeight,
    if (letterSpacingEm != null) 'ls': letterSpacingEm,
    if (marginTopEm != 0) 'mt': marginTopEm,
    if (marginBottomEm != 0) 'mb': marginBottomEm,
    if (blankLinesEm != 0) 'ble': blankLinesEm,
    if (marginLeftEm != 0) 'ml': marginLeftEm,
    if (marginRightEm != 0) 'mr': marginRightEm,
    if (paddingEm != 0) 'pd': paddingEm,
    if (paddingTopEm != 0) 'pt': paddingTopEm,
    if (paddingBottomEm != 0) 'pb': paddingBottomEm,
    if (separateVerticalPadding) 'svp': true,
    if (lineBreakBefore) 'lbb': true,
    if (horizontalBleed) 'hb': true,
    if (imageGallery != null) 'ig': imageGallery,
    if (relativeInsets.isNotEmpty) 'ri': relativeInsets,
    if (ruleHeightEm != null) 'rh': ruleHeightEm,
    if (textColor != null) 'tc': textColor,
    if (backgroundColor != null) 'bg': backgroundColor,
    if (borderColor != null) 'bc': borderColor,
    if (borderLeftWidth != 0) 'blw': borderLeftWidth,
    if (borderWidth != 0) 'bw': borderWidth,
    if (borderTopWidth != 0) 'btw': borderTopWidth,
    if (borderBottomWidth != 0) 'bbw': borderBottomWidth,
    if (borderStyle != null) 'bs': borderStyle,
    if (borderRadius != 0) 'br': borderRadius,
    if (pageBreakBefore) 'pbb': true,
    if (pageBreakAfter) 'pba': true,
    if (listMarker != null) 'lm': listMarker,
    if (tableRows.isNotEmpty) 'tr': tableRows,
    if (caption != null) 'cap': caption,
    if (sideBySideImageUrls.isNotEmpty) 'sbi': sideBySideImageUrls,
    if (imageTapTargets.isNotEmpty) 'itt': imageTapTargets,
    if (floatRightWidthFraction != null) 'frw': floatRightWidthFraction,
  };

  factory EpubBlockStyle.fromJson(Map<String, dynamic> json) {
    final kindName = json['k'] as String?;
    final alignName = json['ta'] as String?;
    return EpubBlockStyle(
      kind: EpubBlockKind.values.firstWhere(
        (e) => e.name == kindName,
        orElse: () => EpubBlockKind.paragraph,
      ),
      fontScale: (json['fs'] as num?)?.toDouble(),
      fontWeight: (json['fw'] as num?)?.toInt(),
      italic: json['it'] == true,
      fontFamily: json['ff'] as String?,
      textAlign: alignName == null
          ? null
          : TextAlign.values.firstWhere(
              (e) => e.name == alignName,
              orElse: () => TextAlign.start,
            ),
      textIndentEm: (json['ti'] as num?)?.toDouble(),
      lineHeight: (json['lh'] as num?)?.toDouble(),
      letterSpacingEm: (json['ls'] as num?)?.toDouble(),
      marginTopEm: (json['mt'] as num?)?.toDouble() ?? 0,
      marginBottomEm: (json['mb'] as num?)?.toDouble() ?? 0,
      blankLinesEm: (json['ble'] as num?)?.toDouble() ?? 0,
      marginLeftEm: (json['ml'] as num?)?.toDouble() ?? 0,
      marginRightEm: (json['mr'] as num?)?.toDouble() ?? 0,
      paddingEm: (json['pd'] as num?)?.toDouble() ?? 0,
      paddingTopEm: (json['pt'] as num?)?.toDouble() ?? 0,
      paddingBottomEm: (json['pb'] as num?)?.toDouble() ?? 0,
      separateVerticalPadding: json['svp'] == true,
      lineBreakBefore: json['lbb'] == true,
      horizontalBleed: json['hb'] == true,
      imageGallery: (json['ig'] as num?)?.toInt(),
      relativeInsets: {
        for (final entry in (json['ri'] as Map? ?? const {}).entries)
          if (entry.key is String && entry.value is num)
            entry.key as String: (entry.value as num).toDouble(),
      },
      ruleHeightEm: (json['rh'] as num?)?.toDouble(),
      textColor: (json['tc'] as num?)?.toInt(),
      backgroundColor: (json['bg'] as num?)?.toInt(),
      borderColor: (json['bc'] as num?)?.toInt(),
      borderLeftWidth: (json['blw'] as num?)?.toDouble() ?? 0,
      borderWidth: (json['bw'] as num?)?.toDouble() ?? 0,
      borderTopWidth: (json['btw'] as num?)?.toDouble() ?? 0,
      borderBottomWidth: (json['bbw'] as num?)?.toDouble() ?? 0,
      borderStyle: json['bs'] as String?,
      borderRadius: (json['br'] as num?)?.toDouble() ?? 0,
      pageBreakBefore: json['pbb'] == true,
      pageBreakAfter: json['pba'] == true,
      listMarker: json['lm'] as String?,
      tableRows:
          (json['tr'] as List?)
              ?.map((r) => (r as List).map((c) => c.toString()).toList())
              .toList() ??
          const [],
      caption: json['cap'] as String?,
      sideBySideImageUrls:
          (json['sbi'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      imageTapTargets:
          (json['itt'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      floatRightWidthFraction: (json['frw'] as num?)?.toDouble(),
    );
  }
}

class EpubInlineSpan {
  const EpubInlineSpan({
    required this.start,
    required this.end,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.underlineColor,
    this.underlineStyle,
    this.underlineOffsetEm,
    this.underlinePaddingLeftEm = 0,
    this.underlinePaddingRightEm = 0,
    this.strike = false,
    this.code = false,
    this.superscript = false,
    this.subscript = false,
    this.fontScale,
    this.fontFamily,
    this.textColor,
    this.backgroundColor,
    this.rubyText,
    this.footnoteId,
    this.inlineImageUrl,
    this.inlineImageLayout,
  });

  final int start;
  final int end;
  final bool bold;
  final bool italic;
  final bool underline;
  final int? underlineColor;
  final String? underlineStyle;
  final double? underlineOffsetEm;
  final double underlinePaddingLeftEm;
  final double underlinePaddingRightEm;
  final bool strike;
  final bool code;
  final bool superscript;
  final bool subscript;
  final double? fontScale;
  final String? fontFamily;
  final int? textColor;
  final int? backgroundColor;
  final String? rubyText;
  final String? footnoteId;
  final String? inlineImageUrl;
  final LocalImageLayout? inlineImageLayout;

  bool get hasFormatting =>
      bold ||
      italic ||
      underline ||
      underlineColor != null ||
      underlineStyle != null ||
      strike ||
      code ||
      superscript ||
      subscript ||
      fontScale != null ||
      fontFamily != null ||
      textColor != null ||
      backgroundColor != null ||
      rubyText != null ||
      footnoteId != null ||
      inlineImageUrl != null;

  EpubInlineSpan copyWithRange(int newStart, int newEnd) => EpubInlineSpan(
    start: newStart,
    end: newEnd,
    bold: bold,
    italic: italic,
    underline: underline,
    underlineColor: underlineColor,
    underlineStyle: underlineStyle,
    underlineOffsetEm: underlineOffsetEm,
    underlinePaddingLeftEm: underlinePaddingLeftEm,
    underlinePaddingRightEm: underlinePaddingRightEm,
    strike: strike,
    code: code,
    superscript: superscript,
    subscript: subscript,
    fontScale: fontScale,
    fontFamily: fontFamily,
    textColor: textColor,
    backgroundColor: backgroundColor,
    rubyText: rubyText,
    footnoteId: footnoteId,
    inlineImageUrl: inlineImageUrl,
    inlineImageLayout: inlineImageLayout,
  );

  EpubInlineSpan? slice(int sliceStart, int sliceEnd) {
    final s = start.clamp(sliceStart, sliceEnd) - sliceStart;
    final e = end.clamp(sliceStart, sliceEnd) - sliceStart;
    if (e <= s) return null;
    return copyWithRange(s, e);
  }

  Map<String, Object?> toJson() => {
    's': start,
    'e': end,
    if (bold) 'b': true,
    if (italic) 'i': true,
    if (underline) 'u': true,
    if (underlineColor != null) 'uc': underlineColor,
    if (underlineStyle != null) 'us': underlineStyle,
    if (underlineOffsetEm != null) 'uo': underlineOffsetEm,
    if (underlinePaddingLeftEm != 0) 'upl': underlinePaddingLeftEm,
    if (underlinePaddingRightEm != 0) 'upr': underlinePaddingRightEm,
    if (strike) 'st': true,
    if (code) 'cd': true,
    if (superscript) 'sup': true,
    if (subscript) 'sub': true,
    if (fontScale != null) 'fs': fontScale,
    if (fontFamily != null) 'ff': fontFamily,
    if (textColor != null) 'tc': textColor,
    if (backgroundColor != null) 'bg': backgroundColor,
    if (rubyText != null) 'rt': rubyText,
    if (footnoteId != null) 'fn': footnoteId,
    if (inlineImageUrl != null) 'img': inlineImageUrl,
    if (inlineImageLayout != null && !inlineImageLayout!.isEmpty)
      'iml': inlineImageLayout!.suffix,
  };

  factory EpubInlineSpan.fromJson(Map<String, dynamic> json) {
    final suffix = json['iml'] as String?;
    return EpubInlineSpan(
      start: (json['s'] as num).toInt(),
      end: (json['e'] as num).toInt(),
      bold: json['b'] == true,
      italic: json['i'] == true,
      underline: json['u'] == true,
      underlineColor: (json['uc'] as num?)?.toInt(),
      underlineStyle: json['us'] as String?,
      underlineOffsetEm: (json['uo'] as num?)?.toDouble(),
      underlinePaddingLeftEm: (json['upl'] as num?)?.toDouble() ?? 0,
      underlinePaddingRightEm: (json['upr'] as num?)?.toDouble() ?? 0,
      strike: json['st'] == true,
      code: json['cd'] == true,
      superscript: json['sup'] == true,
      subscript: json['sub'] == true,
      fontScale: (json['fs'] as num?)?.toDouble(),
      fontFamily: json['ff'] as String?,
      textColor: (json['tc'] as num?)?.toInt(),
      backgroundColor: (json['bg'] as num?)?.toInt(),
      rubyText: json['rt'] as String?,
      footnoteId: json['fn'] as String?,
      inlineImageUrl: json['img'] as String?,
      inlineImageLayout: suffix == null
          ? null
          : LocalImageLayout.parseSuffix(suffix),
    );
  }
}

class EpubFootnote {
  const EpubFootnote({
    required this.id,
    required this.label,
    required this.content,
  });

  final String id;
  final String label;
  final String content;

  Map<String, Object?> toJson() => {'id': id, 'l': label, 'c': content};

  factory EpubFootnote.fromJson(Map<String, dynamic> json) => EpubFootnote(
    id: json['id'] as String? ?? '',
    label: json['l'] as String? ?? '注',
    content: json['c'] as String? ?? '',
  );
}

class EpubHeadingBlock {
  const EpubHeadingBlock({
    required this.text,
    required this.style,
    this.spans = const [],
  });

  final String text;
  final EpubBlockStyle style;
  final List<EpubInlineSpan> spans;

  Map<String, Object?> toJson() => {
    't': text,
    'st': style.toJson(),
    if (spans.isNotEmpty) 'sp': [for (final s in spans) s.toJson()],
  };

  factory EpubHeadingBlock.fromJson(Map<String, dynamic> json) =>
      EpubHeadingBlock(
        text: json['t'] as String? ?? '',
        style: json['st'] is Map
            ? EpubBlockStyle.fromJson(Map<String, dynamic>.from(json['st']))
            : const EpubBlockStyle(kind: EpubBlockKind.heading1),
        spans: [
          for (final raw in (json['sp'] as List? ?? const []))
            if (raw is Map)
              EpubInlineSpan.fromJson(Map<String, dynamic>.from(raw)),
        ],
      );
}

class EpubChapterLayout {
  const EpubChapterLayout({
    this.blocks = const {},
    this.spans = const {},
    this.footnotes = const {},
    this.leadingHeading,
    this.bodyFontFamily,
    this.embeddedFonts = const {},
  });

  final Map<int, EpubBlockStyle> blocks;
  final Map<int, List<EpubInlineSpan>> spans;
  final Map<String, EpubFootnote> footnotes;
  final EpubHeadingBlock? leadingHeading;
  final String? bodyFontFamily;
  final Map<String, String> embeddedFonts;

  bool get isEmpty =>
      blocks.isEmpty &&
      spans.isEmpty &&
      footnotes.isEmpty &&
      leadingHeading == null &&
      bodyFontFamily == null &&
      embeddedFonts.isEmpty;

  bool get hasRichHeading =>
      leadingHeading != null || (blocks[0]?.isHeading ?? false);

  Iterable<String> get inlineImageUrls sync* {
    for (final list in spans.values) {
      for (final span in list) {
        if (span.inlineImageUrl case final url?) yield url;
      }
    }
    for (final block in blocks.values) {
      yield* block.sideBySideImageUrls;
    }
  }

  EpubChapterLayout localized(String Function(String) convert) {
    if (isEmpty) return this;
    return EpubChapterLayout(
      blocks: {
        for (final entry in blocks.entries)
          entry.key: entry.value.copyWith(
            caption: entry.value.caption == null
                ? null
                : convert(entry.value.caption!),
            tableRows: entry.value.tableRows
                .map((row) => row.map(convert).toList())
                .toList(),
          ),
      },
      spans: {
        for (final entry in spans.entries)
          entry.key: [
            for (final span in entry.value)
              span.rubyText == null
                  ? span
                  : EpubInlineSpan(
                      start: span.start,
                      end: span.end,
                      bold: span.bold,
                      italic: span.italic,
                      underline: span.underline,
                      underlineColor: span.underlineColor,
                      underlineStyle: span.underlineStyle,
                      underlineOffsetEm: span.underlineOffsetEm,
                      underlinePaddingLeftEm: span.underlinePaddingLeftEm,
                      underlinePaddingRightEm: span.underlinePaddingRightEm,
                      strike: span.strike,
                      code: span.code,
                      superscript: span.superscript,
                      subscript: span.subscript,
                      fontScale: span.fontScale,
                      fontFamily: span.fontFamily,
                      textColor: span.textColor,
                      backgroundColor: span.backgroundColor,
                      rubyText: convert(span.rubyText!),
                      footnoteId: span.footnoteId,
                      inlineImageUrl: span.inlineImageUrl,
                      inlineImageLayout: span.inlineImageLayout,
                    ),
          ],
      },
      footnotes: {
        for (final entry in footnotes.entries)
          entry.key: EpubFootnote(
            id: entry.value.id,
            label: convert(entry.value.label),
            content: convert(entry.value.content),
          ),
      },
      leadingHeading: leadingHeading == null
          ? null
          : EpubHeadingBlock(
              text: convert(leadingHeading!.text),
              style: leadingHeading!.style,
              spans: leadingHeading!.spans,
            ),
      bodyFontFamily: bodyFontFamily,
      embeddedFonts: embeddedFonts,
    );
  }

  Map<String, Object?> toJson() => {
    if (blocks.isNotEmpty)
      'b': {for (final e in blocks.entries) '${e.key}': e.value.toJson()},
    if (spans.isNotEmpty)
      's': {
        for (final e in spans.entries)
          if (e.value.isNotEmpty)
            '${e.key}': [for (final span in e.value) span.toJson()],
      },
    if (footnotes.isNotEmpty)
      'f': {for (final e in footnotes.entries) e.key: e.value.toJson()},
    if (leadingHeading != null) 'lh': leadingHeading!.toJson(),
    if (bodyFontFamily != null) 'bf': bodyFontFamily,
    if (embeddedFonts.isNotEmpty) 'ef': embeddedFonts,
  };

  factory EpubChapterLayout.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['b'] as Map?;
    final rawSpans = json['s'] as Map?;
    final rawFootnotes = json['f'] as Map?;
    final rawFonts = json['ef'] as Map?;
    return EpubChapterLayout(
      blocks: {
        if (rawBlocks != null)
          for (final e in rawBlocks.entries)
            if (int.tryParse(e.key.toString()) case final index?)
              if (e.value is Map)
                index: EpubBlockStyle.fromJson(
                  Map<String, dynamic>.from(e.value as Map),
                ),
      },
      spans: {
        if (rawSpans != null)
          for (final e in rawSpans.entries)
            if (int.tryParse(e.key.toString()) case final index?)
              if (e.value is List)
                index: [
                  for (final item in (e.value as List))
                    if (item is Map)
                      EpubInlineSpan.fromJson(Map<String, dynamic>.from(item)),
                ],
      },
      footnotes: {
        if (rawFootnotes != null)
          for (final e in rawFootnotes.entries)
            if (e.value is Map)
              e.key.toString(): EpubFootnote.fromJson(
                Map<String, dynamic>.from(e.value as Map),
              ),
      },
      leadingHeading: json['lh'] is Map
          ? EpubHeadingBlock.fromJson(
              Map<String, dynamic>.from(json['lh'] as Map),
            )
          : null,
      bodyFontFamily: json['bf'] as String?,
      embeddedFonts: {
        if (rawFonts != null)
          for (final e in rawFonts.entries)
            e.key.toString(): e.value.toString(),
      },
    );
  }
}

/// Adapts EPUB CSS colors so they remain legible across light, sepia, green,
/// and night reader themes.
class EpubColorAdapter {
  static Color adaptTextColor(
    Color source, {
    required Color paperColor,
    required Color defaultTextColor,
    Color? backgroundColor,
  }) {
    if (source.a < 0.1) return defaultTextColor;
    final effectiveSurface = backgroundColor ?? paperColor;
    final dark = effectiveSurface.computeLuminance() < 0.35;
    final hsl = HSLColor.fromColor(source);
    // When rendered on an explicit inline badge background (e.g. white text on
    // a #65678a pill), keep high-contrast foreground colors intact.
    if (backgroundColor != null) {
      if (dark && hsl.lightness >= 0.55) return source;
      if (!dark && hsl.lightness <= 0.45) return source;
    }
    // Near-grayscale black/dark-gray text from EPUB stylesheets should follow
    // the reader's chosen foreground color unless it has distinct hue or lightness.
    if (hsl.saturation < 0.12 && hsl.lightness < 0.25) {
      return defaultTextColor;
    }
    if (dark) {
      if (hsl.lightness < 0.55) {
        return hsl
            .withLightness((1.0 - hsl.lightness * 0.65).clamp(0.62, 0.92))
            .toColor();
      }
      return source;
    } else {
      // Preserve intentional pastel/accent colors (like coral #ff9b83 at 0.76
      // lightness) on light paper; only darken near-white text that would
      // vanish against a light background.
      if (hsl.lightness > 0.86 ||
          (hsl.saturation < 0.25 && hsl.lightness > 0.76)) {
        return hsl
            .withLightness((hsl.lightness * 0.62).clamp(0.32, 0.58))
            .toColor();
      }
      return source;
    }
  }

  static Color? adaptBackgroundColor(
    Color? source, {
    required Color paperColor,
    required Color defaultTextColor,
    bool isInlineBadge = false,
  }) {
    final dark = paperColor.computeLuminance() < 0.35;
    if (source == null) {
      return defaultTextColor.withValues(alpha: dark ? 0.07 : 0.045);
    }
    if (source.a < 0.05) return null;
    if (isInlineBadge) {
      return source.withValues(alpha: dark ? 0.85 : 0.94);
    }
    final hsl = HSLColor.fromColor(source);
    if (dark) {
      if (hsl.lightness > 0.45) {
        return hsl
            .withLightness(0.18)
            .withSaturation((hsl.saturation * 0.5).clamp(0.0, 0.35))
            .toColor()
            .withValues(alpha: 0.72);
      }
      return source.withValues(alpha: 0.55);
    } else {
      if (hsl.lightness < 0.4) {
        return hsl
            .withLightness(0.92)
            .withSaturation((hsl.saturation * 0.4).clamp(0.0, 0.3))
            .toColor()
            .withValues(alpha: 0.75);
      }
      return source.withValues(alpha: 0.65);
    }
  }

  static Color adaptBorderColor(
    Color? source, {
    required Color paperColor,
    required Color defaultTextColor,
  }) {
    final dark = paperColor.computeLuminance() < 0.35;
    if (source == null) {
      return defaultTextColor.withValues(alpha: dark ? 0.45 : 0.38);
    }
    final hsl = HSLColor.fromColor(source);
    if (dark) {
      if (hsl.lightness < 0.4) {
        return hsl.withLightness(0.65).toColor().withValues(alpha: 0.75);
      }
      if (hsl.lightness > 0.82) {
        return hsl.withLightness(0.38).toColor().withValues(alpha: 0.75);
      }
      return source.withValues(alpha: 0.75);
    }
    return source.withValues(alpha: 0.85);
  }
}

/// Bounded in-memory association between chapter body strings and their parsed
/// EPUB rich layout metadata.
class EpubLayoutRegistry {
  static final _byBody = <String, EpubChapterLayout>{};

  static String _normalize(String body) {
    var trimmed = body.trimRight();
    while (true) {
      final marker = trimmed.lastIndexOf('<!--reader-rich-v1:');
      if (marker > 0 && trimmed.endsWith('-->')) {
        trimmed = trimmed.substring(0, marker).trimRight();
      } else if (trimmed.startsWith('<!--reader-rich-v1:') &&
          trimmed.endsWith('-->')) {
        return '';
      } else {
        break;
      }
    }
    return trimmed;
  }

  static void register(String body, EpubChapterLayout layout) {
    final key = _normalize(body);
    if (key.isEmpty || layout.isEmpty) return;
    _byBody.remove(key);
    _byBody[key] = layout;
    if (_byBody.length > 64) {
      _byBody.remove(_byBody.keys.first);
    }
  }

  static EpubChapterLayout? lookup(String body) {
    final key = _normalize(body);
    final found = _byBody.remove(key);
    if (found != null) {
      _byBody[key] = found;
    }
    return found;
  }

  static void clear() => _byBody.clear();
}

/// Manages dynamic registration and de-obfuscation of embedded EPUB fonts.
class EpubFontManager {
  static final _loadedFamilies = <String>{};
  static final _memoryFonts = <String, Uint8List>{};

  static String runtimeFamilyName(int bookId, String fontFileOrFamily) =>
      'epub_font_${bookId}_$fontFileOrFamily';

  static String _normalizeFamilyName(String raw) => raw
      .trim()
      .replaceAll(RegExp(r'''^['"]+|['"]+$'''), '')
      .trim()
      .toLowerCase();

  static void registerMemoryFont(
    int bookId,
    String cssFamilyOrFile,
    Uint8List bytes,
  ) {
    _memoryFonts[runtimeFamilyName(bookId, cssFamilyOrFile)] = bytes;
    _memoryFonts[runtimeFamilyName(
          bookId,
          _normalizeFamilyName(cssFamilyOrFile),
        )] =
        bytes;
  }

  static Future<void> ensureLoaded({
    required int bookId,
    required Map<String, String> embeddedFonts,
    Directory? bookDirectory,
  }) async {
    for (final entry in embeddedFonts.entries) {
      final family = runtimeFamilyName(bookId, entry.value);
      if (_loadedFamilies.contains(family)) continue;
      Uint8List? bytes =
          _memoryFonts[family] ??
          _memoryFonts[runtimeFamilyName(bookId, entry.key)] ??
          _memoryFonts[runtimeFamilyName(
            bookId,
            _normalizeFamilyName(entry.key),
          )];
      if (bytes == null && bookDirectory != null) {
        final file = File('${bookDirectory.path}/${entry.value}');
        if (await file.exists()) {
          try {
            bytes = await file.readAsBytes();
          } catch (_) {
            continue;
          }
        }
      }
      if (bytes == null || bytes.isEmpty) continue;
      try {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        _loadedFamilies.add(family);
      } catch (_) {
        /* Malformed embedded font falls back to reader/system typeface. */
      }
    }
  }

  /// Resolves the runtime font family name for `cssFamily` if embedded in `embeddedFonts`.
  static String? resolveFontFamily(
    int? bookId,
    String? cssFamily,
    Map<String, String> embeddedFonts,
  ) {
    if (bookId == null || cssFamily == null || embeddedFonts.isEmpty) {
      return null;
    }
    final norm = _normalizeFamilyName(cssFamily);
    for (final entry in embeddedFonts.entries) {
      if (_normalizeFamilyName(entry.key) == norm) {
        return runtimeFamilyName(bookId, entry.value);
      }
    }
    return null;
  }

  /// Returns platform CJK fallback font families for Duokan and standard Chinese
  /// font aliases (`DK-KAITI`, `楷体`, `DK-HEITI`, `黑体`, `小标宋`, `细黑`, etc.).
  static List<String>? fontFamilyFallbacksFor(String? cssFamily) {
    if (cssFamily == null || cssFamily.isEmpty) return null;
    final norm = _normalizeFamilyName(cssFamily);
    if (norm.contains('kaiti') ||
        norm.contains('楷') ||
        norm == 'kt' ||
        norm == 'dk-kaiti') {
      return const [
        'KaiTi',
        'STKaiti',
        'DFKai-SB',
        'Kaiti SC',
        'Noto Serif CJK SC',
        'Noto Serif SC',
        'Source Han Serif SC',
        'serif',
      ];
    }
    if (norm.contains('song') ||
        norm.contains('宋') ||
        norm == 'st' ||
        norm == 'dk-songti' ||
        norm.contains('ming') ||
        norm.contains('明')) {
      return const [
        'Songti SC',
        'STSong',
        'SimSun',
        'NSimSun',
        'Noto Serif CJK SC',
        'Noto Serif SC',
        'Source Han Serif SC',
        'serif',
      ];
    }
    if (norm.contains('hei') ||
        norm.contains('黑') ||
        norm == 'ht' ||
        norm == 'dk-heiti') {
      return const [
        'PingFang SC',
        'Heiti SC',
        'Microsoft YaHei',
        'SimHei',
        'Noto Sans CJK SC',
        'Noto Sans SC',
        'Source Han Sans SC',
        'sans-serif',
      ];
    }
    return null;
  }

  /// Parses `META-INF/encryption.xml` and returns a map of archive path ->
  /// obfuscation algorithm URI (`http://www.idpf.org/2008/embedding` or
  /// `http://ns.adobe.com/pdf/enc#RC`).
  static Map<String, String> parseEncryptionAlgorithms(String encryptionXml) {
    final result = <String, String>{};
    try {
      final doc = XmlDocument.parse(encryptionXml);
      for (final data in doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'EncryptedData',
      )) {
        final method = data.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'EncryptionMethod')
            .firstOrNull
            ?.getAttribute('Algorithm');
        final uri = data.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'CipherReference')
            .firstOrNull
            ?.getAttribute('URI');
        if (method != null && uri != null) {
          result[Uri.decodeComponent(uri)] = method;
        }
      }
    } catch (_) {}
    return result;
  }

  /// De-obfuscates IDPF or Adobe font bytes using the OPF unique identifier.
  static Uint8List deobfuscateFont(
    Uint8List bytes, {
    required String? algorithm,
    required String uniqueIdentifier,
  }) {
    if (algorithm == null || uniqueIdentifier.trim().isEmpty) return bytes;
    final cleanId = uniqueIdentifier.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (algorithm == 'http://www.idpf.org/2008/embedding') {
      final key = sha1.convert(utf8.encode(cleanId)).bytes;
      final out = Uint8List.fromList(bytes);
      final limit = out.length < 1040 ? out.length : 1040;
      for (var i = 0; i < limit; i++) {
        out[i] ^= key[i % key.length];
      }
      return out;
    }
    if (algorithm == 'http://ns.adobe.com/pdf/enc#RC') {
      final hex = cleanId
          .replaceAll(RegExp(r'^urn:uuid:', caseSensitive: false), '')
          .replaceAll('-', '');
      List<int> key;
      if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
        key = [
          for (var i = 0; i < 32; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ];
      } else {
        key = md5.convert(utf8.encode(cleanId)).bytes;
      }
      final out = Uint8List.fromList(bytes);
      final limit = out.length < 1024 ? out.length : 1024;
      for (var i = 0; i < limit; i++) {
        out[i] ^= key[i % key.length];
      }
      return out;
    }
    return bytes;
  }
}

/// Parses `@font-face` declarations and element CSS properties from a chapter's
/// stylesheets and inline styles.
class EpubStylesheetRules {
  EpubStylesheetRules({
    required this.fontFaces,
    required this.elementProps,
    required this.bodyFontFamily,
  });

  /// Maps normalized CSS `font-family` name -> stylesheet-relative font `src` href.
  final Map<String, ({String family, String href, String baseHref})> fontFaces;

  /// Maps DOM `Element` -> cascaded CSS property map (`property -> value`).
  final Map<html.Element, Map<String, String>> elementProps;

  /// Default `font-family` declared on `body`, if any.
  final String? bodyFontFamily;
}

const _trackedCssProperties = {
  'duokan-bleed',
  'font',
  'font-size',
  'font-weight',
  'font-style',
  'font-family',
  'text-align',
  'text-indent',
  'text-decoration',
  'vertical-align',
  'color',
  'background-color',
  'background',
  'border',
  'border-top',
  'border-top-width',
  'border-top-color',
  'border-top-style',
  'border-right',
  'border-left',
  'border-left-width',
  'border-left-color',
  'border-left-style',
  'border-bottom',
  'border-bottom-width',
  'border-bottom-color',
  'border-bottom-style',
  'border-color',
  'border-width',
  'border-style',
  'border-radius',
  'line-height',
  'letter-spacing',
  'display',
  'opacity',
  'writing-mode',
  '-epub-writing-mode',
  'float',
  'width',
  'margin',
  'margin-top',
  'margin-bottom',
  'margin-left',
  'margin-right',
  'margin-block',
  'margin-block-start',
  'margin-block-end',
  'padding',
  'padding-top',
  'padding-bottom',
  'padding-left',
  'padding-right',
  'padding-block',
  'padding-block-start',
  'padding-block-end',
  'page-break-before',
  'page-break-after',
  'break-before',
  'break-after',
};

const _inheritableCssProperties = {
  'font-size',
  'font-weight',
  'font-style',
  'font-family',
  'text-align',
  'text-indent',
  'line-height',
  'letter-spacing',
  'color',
  'writing-mode',
  '-epub-writing-mode',
};

EpubStylesheetRules resolveEpubStyles(
  html.Document document,
  String chapterPath,
  String? Function(String href) readStylesheet,
) {
  final fontFaces = <String, ({String family, String href, String baseHref})>{};
  final values =
      <
        html.Element,
        Map<String, ({String value, bool important, int specificity})>
      >{};

  void setSingleProp(
    html.Element element,
    String prop,
    String value,
    bool important,
    int specificity,
  ) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    final map = values.putIfAbsent(element, () => {});
    final old = map[prop];
    if (old != null &&
        (old.important && !important ||
            old.important == important && old.specificity > specificity)) {
      return;
    }
    map[prop] = (value: clean, important: important, specificity: specificity);
  }

  void expandBoxShorthand(
    html.Element element,
    String prefix,
    String clean,
    bool important,
    int specificity,
  ) {
    final parts = clean.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return;
    final top = parts[0];
    final right = parts.length >= 2 ? parts[1] : top;
    final bottom = parts.length >= 3 ? parts[2] : top;
    final left = parts.length >= 4 ? parts[3] : right;
    setSingleProp(element, '$prefix-top', top, important, specificity);
    setSingleProp(element, '$prefix-right', right, important, specificity);
    setSingleProp(element, '$prefix-bottom', bottom, important, specificity);
    setSingleProp(element, '$prefix-left', left, important, specificity);
  }

  void expandFontShorthand(
    html.Element element,
    String clean,
    bool important,
    int specificity,
  ) {
    final match = RegExp(
      r'(?:^|\s)((?:\d+(?:\.\d+)?|\.\d+)(?:r?em|%|px|pt)|xx-small|x-small|small|medium|large|x-large|xx-large|smaller|larger)(?:\s*/\s*(\d+(?:\.\d+)?(?:r?em|%|px|pt)?))?(?=\s|$)',
      caseSensitive: false,
    ).firstMatch(clean);
    if (match == null) return;
    final pre = clean.substring(0, match.start).toLowerCase();
    final sizeToken = match.group(1)!.trim();
    final lhToken = match.group(2)?.trim();
    final familyPart = clean.substring(match.end).trim();

    if (pre.contains('italic') || pre.contains('oblique')) {
      setSingleProp(element, 'font-style', 'italic', important, specificity);
    } else {
      setSingleProp(element, 'font-style', 'normal', important, specificity);
    }
    if (pre.contains('bold') ||
        pre.contains('bolder') ||
        RegExp(r'\b[6-9]00\b').hasMatch(pre)) {
      setSingleProp(element, 'font-weight', 'bold', important, specificity);
    } else {
      setSingleProp(element, 'font-weight', 'normal', important, specificity);
    }
    setSingleProp(element, 'font-size', sizeToken, important, specificity);
    setSingleProp(
      element,
      'line-height',
      lhToken ?? 'normal',
      important,
      specificity,
    );
    if (familyPart.isNotEmpty) {
      setSingleProp(element, 'font-family', familyPart, important, specificity);
    }
  }

  void setProp(
    html.Element element,
    String prop,
    String value,
    bool important,
    int specificity,
  ) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    setSingleProp(element, prop, clean, important, specificity);
    switch (prop) {
      case 'margin':
      case 'padding':
        expandBoxShorthand(element, prop, clean, important, specificity);
      case 'margin-block':
      case 'padding-block':
        final prefix = prop.startsWith('margin') ? 'margin' : 'padding';
        final parts = clean
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) {
          setSingleProp(element, '$prefix-top', parts[0], important, specificity);
          setSingleProp(
            element,
            '$prefix-bottom',
            parts.length > 1 ? parts[1] : parts[0],
            important,
            specificity,
          );
        }
      case 'margin-block-start':
        setSingleProp(element, 'margin-top', clean, important, specificity);
      case 'margin-block-end':
        setSingleProp(element, 'margin-bottom', clean, important, specificity);
      case 'padding-block-start':
        setSingleProp(element, 'padding-top', clean, important, specificity);
      case 'padding-block-end':
        setSingleProp(element, 'padding-bottom', clean, important, specificity);
      case 'border':
        setSingleProp(element, 'border-top', clean, important, specificity);
        setSingleProp(element, 'border-right', clean, important, specificity);
        setSingleProp(element, 'border-bottom', clean, important, specificity);
        setSingleProp(element, 'border-left', clean, important, specificity);
      case 'font':
        expandFontShorthand(element, clean, important, specificity);
    }
  }

  void applyGroup(
    html.Element element,
    ast.DeclarationGroup group,
    int specificity,
  ) {
    for (final declaration in group.declarations.whereType<ast.Declaration>()) {
      final name = declaration.property.toLowerCase();
      if (!_trackedCssProperties.contains(name)) continue;
      final expression = declaration.expression;
      if (expression == null) continue;
      final printer = ast.CssPrinter();
      expression.visit(printer);
      final value = printer.toString().trim();
      if (value.isEmpty) continue;
      setProp(element, name, value, declaration.important, specificity);
    }
  }

  void applyRawDeclarations(
    html.Element element,
    String rawBody,
    int specificity,
  ) {
    for (final part in rawBody.split(';')) {
      final colon = part.indexOf(':');
      if (colon <= 0) continue;
      final name = part.substring(0, colon).trim().toLowerCase();
      if (!_trackedCssProperties.contains(name)) continue;
      var val = part.substring(colon + 1).trim();
      var important = false;
      if (val.toLowerCase().endsWith('!important')) {
        important = true;
        val = val.substring(0, val.length - 10).trim();
      }
      if (val.isNotEmpty) {
        setProp(element, name, val, important, specificity);
      }
    }
  }

  int computeSelectorSpecificity(String sel) {
    var spec = 0;
    spec += RegExp(r'#[a-zA-Z0-9_-]+').allMatches(sel).length * 1000000;
    spec +=
        RegExp(r'(\.[a-zA-Z0-9_-]+|\[[^\]]+\])').allMatches(sel).length * 1000;
    spec +=
        RegExp(r'(^|[\s>+~])([a-zA-Z][a-zA-Z0-9]*)').allMatches(sel).length * 1;
    return spec;
  }

  void parseFontFaces(String cssText, String baseHref) {
    final fontFaceRegex = RegExp(
      r'@font-face\s*\{([^}]*)\}',
      caseSensitive: false,
      multiLine: true,
    );
    for (final match in fontFaceRegex.allMatches(cssText)) {
      final body = match.group(1) ?? '';
      final familyMatch = RegExp(
        r'''font-family\s*:\s*(['"]?)([^;'"]+)\1''',
        caseSensitive: false,
      ).firstMatch(body);
      final urlMatch = RegExp(
        r'''url\(\s*(['"]?)([^)'"]+)\1\s*\)''',
        caseSensitive: false,
      ).firstMatch(body);
      if (familyMatch != null && urlMatch != null) {
        final family = familyMatch.group(2)!.trim();
        final href = urlMatch.group(2)!.trim();
        if (family.isNotEmpty && href.isNotEmpty && !href.startsWith('data:')) {
          fontFaces[family.toLowerCase()] = (
            family: family,
            href: href,
            baseHref: baseHref,
          );
        }
      }
    }
  }

  final visitedSheets = <String>{};
  void processCssText(String text, String baseHref, [int depth = 0]) {
    if (text.isEmpty || depth > 2) return;
    final cleanText = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    parseFontFaces(cleanText, baseHref);

    // Follow @import rules if present.
    final importRegex = RegExp(
      r'''@import\s+(?:url\(\s*(['"]?)([^)'"]+)\1\s*\)|(['"])([^'"]+)\3)''',
      caseSensitive: false,
    );
    for (final m in importRegex.allMatches(cleanText)) {
      final importHref = (m.group(2) ?? m.group(4) ?? '').trim();
      if (importHref.isNotEmpty && visitedSheets.add(importHref)) {
        final imported = readStylesheet(importHref);
        if (imported != null && imported.isNotEmpty) {
          processCssText(imported, importHref, depth + 1);
        }
      }
    }

    ast.StyleSheet? sheet;
    try {
      sheet = css.parse(cleanText);
    } catch (_) {
      sheet = null;
    }
    if (sheet != null && sheet.topLevels.whereType<ast.RuleSet>().isNotEmpty) {
      for (final rule in sheet.topLevels.whereType<ast.RuleSet>()) {
        for (final selector
            in rule.selectorGroup?.selectors ?? <ast.Selector>[]) {
          final query = selector.span?.text.trim();
          if (query == null || query.isEmpty || query.contains(':')) continue;
          final specificity = selector.simpleSelectorSequences.fold<int>(
            0,
            (sum, s) =>
                sum +
                switch (s.simpleSelector) {
                  ast.IdSelector() => 1000000,
                  ast.ClassSelector() ||
                  ast.AttributeSelector() ||
                  ast.PseudoClassSelector() => 1000,
                  ast.ElementSelector() => 1,
                  _ => 0,
                },
          );
          try {
            for (final el in document.querySelectorAll(query)) {
              applyGroup(el, rule.declarationGroup, specificity);
            }
          } catch (_) {
            /* Unsupported selector syntax does not abort chapter styles. */
          }
        }
      }
    } else {
      // Fallback rule-by-rule regex parser so proprietary EPUB/Duokan rules
      // never cause the entire stylesheet to be discarded.
      final ruleRegex = RegExp(r'([^{}@]+)\{([^}]*)\}', multiLine: true);
      for (final m in ruleRegex.allMatches(cleanText)) {
        final selectorGroup = m.group(1)!.trim();
        final body = m.group(2)!.trim();
        if (selectorGroup.isEmpty || body.isEmpty) continue;
        for (final rawSel in selectorGroup.split(',')) {
          final query = rawSel.trim();
          if (query.isEmpty || query.contains(':')) continue;
          final specificity = computeSelectorSpecificity(query);
          try {
            for (final el in document.querySelectorAll(query)) {
              applyRawDeclarations(el, body, specificity);
            }
          } catch (_) {}
        }
      }
    }
  }

  for (final source in document.querySelectorAll(
    'style, link[rel~="stylesheet"], link[type="text/css"][href], link[href\$=".css"]',
  )) {
    final isInlineStyle = source.localName == 'style';
    final href = source.attributes['href'] ?? '';
    if (!isInlineStyle && !visitedSheets.add(href)) continue;
    final text = isInlineStyle ? source.text : readStylesheet(href);
    if (text == null || text.isEmpty) continue;
    final baseHref = isInlineStyle ? chapterPath : href;
    processCssText(text, baseHref);
  }

  for (final el in document.querySelectorAll('[align], [style]')) {
    if (el.attributes['align'] case final align?) {
      setProp(el, 'text-align', align.toLowerCase(), false, 0);
    }
    if (el.attributes['style'] case final inline?) {
      applyRawDeclarations(el, inline, 1000000000);
    }
  }

  final props = <html.Element, Map<String, String>>{
    for (final entry in values.entries)
      entry.key: {
        for (final p in entry.value.entries) p.key: p.value.value,
      },
  };

  final body = document.body;
  String? bodyFont;
  if (body != null && props[body]?['font-family'] != null) {
    bodyFont = _firstFontFamily(props[body]!['font-family']!);
  }

  return EpubStylesheetRules(
    fontFaces: fontFaces,
    elementProps: props,
    bodyFontFamily: bodyFont,
  );
}

String? _firstFontFamily(String raw) {
  for (final part in raw.split(',')) {
    final cleaned = part
        .trim()
        .replaceAll(RegExp(r'''^['"]+|['"]+$'''), '')
        .trim();
    if (cleaned.isEmpty) continue;
    final lower = cleaned.toLowerCase();
    if (const {
      'serif',
      'sans-serif',
      'monospace',
      'cursive',
      'fantasy',
      'system-ui',
      'inherit',
      'initial',
      'default',
    }.contains(lower)) {
      continue;
    }
    return cleaned;
  }
  return null;
}

double? _parseEmOrScale(String? raw, {double basePx = 16.0}) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  return switch (s) {
    'xx-small' => 0.65,
    'x-small' => 0.75,
    'small' || 'smaller' => 0.88,
    'medium' || 'normal' => 1.0,
    'large' || 'larger' => 1.15,
    'x-large' => 1.35,
    'xx-large' => 1.6,
    _ => () {
      final m = RegExp(
        r'^(-?\d+(?:\.\d+)?)\s*(r?em|%|px|pt)?$',
      ).firstMatch(s);
      if (m == null) return null;
      final n = double.tryParse(m.group(1)!);
      if (n == null || !n.isFinite) return null;
      return switch (m.group(2)) {
        'em' || 'rem' || null => n,
        '%' => n / 100.0,
        'px' => n / basePx,
        'pt' => (n * 4.0 / 3.0) / basePx,
        _ => null,
      };
    }(),
  };
}

int? _parseFontWeight(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (s == 'bold' || s == 'bolder') return 700;
  if (s == 'normal' || s == 'lighter') return 400;
  final n = int.tryParse(s);
  if (n != null && n >= 100 && n <= 900) return n;
  return null;
}

TextAlign? _parseTextAlign(String? raw) {
  if (raw == null) return null;
  return switch (raw.trim().toLowerCase()) {
    'center' => TextAlign.center,
    'right' || 'end' => TextAlign.end,
    'left' || 'start' => TextAlign.start,
    'justify' => TextAlign.justify,
    _ => null,
  };
}

int? _parseCssColor(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (s.isEmpty ||
      s == 'inherit' ||
      s == 'initial' ||
      s == 'transparent' ||
      s == 'none' ||
      s == 'currentcolor') {
    return null;
  }
  const named = <String, int>{
    'black': 0xFF000000,
    'white': 0xFFFFFFFF,
    'red': 0xFFD32F2F,
    'darkred': 0xFF8B0000,
    'blue': 0xFF1976D2,
    'darkblue': 0xFF00008B,
    'navy': 0xFF001F3F,
    'green': 0xFF2E7D32,
    'darkgreen': 0xFF006400,
    'gray': 0xFF757575,
    'grey': 0xFF757575,
    'dimgray': 0xFF696969,
    'dimgrey': 0xFF696969,
    'darkgray': 0xFF616161,
    'darkgrey': 0xFF616161,
    'lightgray': 0xFFE0E0E0,
    'lightgrey': 0xFFE0E0E0,
    'silver': 0xFFC0C0C0,
    'brown': 0xFF795548,
    'maroon': 0xFF800000,
    'purple': 0xFF7B1FA2,
    'orange': 0xFFE65100,
    'gold': 0xFFB8860B,
    'teal': 0xFF00796B,
    'olive': 0xFF808000,
    'ivory': 0xFFFFFFF0,
    'beige': 0xFFF5F5DC,
    'whitesmoke': 0xFFF5F5F5,
  };
  if (named[s] case final v?) return v;
  final hex = RegExp(r'#([0-9a-f]{3,8})\b').firstMatch(s)?.group(1);
  if (hex != null) {
    if (hex.length == 3) {
      final r = int.parse(hex[0] * 2, radix: 16);
      final g = int.parse(hex[1] * 2, radix: 16);
      final b = int.parse(hex[2] * 2, radix: 16);
      return 0xFF000000 | (r << 16) | (g << 8) | b;
    }
    if (hex.length == 6) {
      return 0xFF000000 | int.parse(hex, radix: 16);
    }
    if (hex.length == 8) {
      final rrggbb = int.parse(hex.substring(0, 6), radix: 16);
      final aa = int.parse(hex.substring(6, 8), radix: 16);
      return (aa << 24) | rrggbb;
    }
  }
  final rgb = RegExp(
    r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)',
  ).firstMatch(s);
  if (rgb != null) {
    final r = int.parse(rgb.group(1)!).clamp(0, 255);
    final g = int.parse(rgb.group(2)!).clamp(0, 255);
    final b = int.parse(rgb.group(3)!).clamp(0, 255);
    final a = rgb.group(4) == null
        ? 255
        : ((double.tryParse(rgb.group(4)!) ?? 1.0) * 255).round().clamp(0, 255);
    if (a == 0) return null;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }
  return null;
}

({double top, double right, double bottom, double left}) _parseBoxShorthand(
  Map<String, String> props,
  String prefix, {
  bool percentages = false,
  double emScale = 1,
}) {
  double? parse(String value) => value.trim().endsWith('%')
      ? (percentages ? _parseEmOrScale(value) : 0)
      : (percentages
            ? 0
            : (_parseEmOrScale(value) ?? 0) *
                  (value.trim().endsWith('em') && !value.trim().endsWith('rem')
                      ? emScale
                      : 1));
  var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0;
  if (props[prefix] case final shorthand?) {
    final parts = shorthand
        .trim()
        .split(RegExp(r'\s+'))
        .map((p) => (parse(p) ?? 0.0).clamp(0.0, 4.0))
        .toList();
    if (parts.length == 1) {
      top = right = bottom = left = parts[0];
    } else if (parts.length == 2) {
      top = bottom = parts[0];
      right = left = parts[1];
    } else if (parts.length == 3) {
      top = parts[0];
      right = left = parts[1];
      bottom = parts[2];
    } else if (parts.length >= 4) {
      top = parts[0];
      right = parts[1];
      bottom = parts[2];
      left = parts[3];
    }
  }
  if (props['$prefix-top'] case final v?) {
    top = (parse(v) ?? top).clamp(0.0, 4.0);
  }
  if (props['$prefix-right'] case final v?) {
    right = (parse(v) ?? right).clamp(0.0, 4.0);
  }
  if (props['$prefix-bottom'] case final v?) {
    bottom = (parse(v) ?? bottom).clamp(0.0, 4.0);
  }
  if (props['$prefix-left'] case final v?) {
    left = (parse(v) ?? left).clamp(0.0, 4.0);
  }
  return (top: top, right: right, bottom: bottom, left: left);
}

({double width, int? color, String? style}) _parseBorderSide(String? raw) {
  if (raw == null) return (width: 0, color: null, style: null);
  final lower = raw.toLowerCase();
  if (lower.contains('none') ||
      lower.contains('hidden') ||
      RegExp(r'^0(px|pt|r?em)?$').hasMatch(lower.trim())) {
    return (width: 0, color: null, style: 'none');
  }
  var width = 1.5;
  final px = RegExp(r'(\d+(?:\.\d+)?)\s*(px|pt|r?em)').firstMatch(lower);
  if (px != null) {
    final v = double.tryParse(px.group(1)!) ?? 1.5;
    final unit = px.group(2);
    width = (unit == 'em' || unit == 'rem' ? v * 16 : v).clamp(0.0, 18.0);
  } else if (lower.contains('thick')) {
    width = 3.0;
  } else if (lower.contains('medium')) {
    width = 2.0;
  } else if (lower.contains('thin')) {
    width = 1.0;
  }
  String? style;
  if (lower.contains('dotted')) {
    style = 'dotted';
  } else if (lower.contains('dashed')) {
    style = 'dashed';
  } else if (lower.contains('double')) {
    style = 'double';
  } else if (lower.contains('solid')) {
    style = 'solid';
  }
  return (width: width, color: _parseCssColor(raw), style: style);
}

bool _hasClass(html.Element el, Pattern pattern) =>
    el.classes.any((c) => pattern.allMatches(c).isNotEmpty);

String? _epubType(html.Element el) =>
    el.attributes['epub:type'] ??
    el.attributes.entries
        .where((e) => e.key.toString().endsWith(':type'))
        .firstOrNull
        ?.value;

bool _isFootnoteDefinition(html.Element el) {
  final epubType = _epubType(el)?.toLowerCase() ?? '';
  if (epubType.contains('footnote') ||
      epubType.contains('rearnote') ||
      epubType.contains('endnote')) {
    return true;
  }
  final role = el.attributes['role']?.toLowerCase() ?? '';
  if (role == 'doc-footnote' || role == 'doc-endnote') return true;
  if (el.localName == 'aside' &&
      (epubType.contains('note') ||
          _hasClass(
            el,
            RegExp(r'footnote|duokan-footnote', caseSensitive: false),
          ))) {
    return true;
  }
  if (_hasClass(
    el,
    RegExp(
      r'^(duokan-footnote-item|duokan-footnote-content|footnote-item|footnote-text|endnote|note-item)$',
      caseSensitive: false,
    ),
  )) {
    return true;
  }
  return false;
}

bool _isFootnoteLink(html.Element el) {
  if (el.localName != 'a') return false;
  final href = el.attributes['href'] ?? '';
  if (!href.contains('#')) return false;
  final epubType = _epubType(el)?.toLowerCase() ?? '';
  if (epubType.contains('noteref')) return true;
  final role = el.attributes['role']?.toLowerCase() ?? '';
  if (role == 'doc-noteref') return true;
  if (el.attributes['rel']?.toLowerCase() == 'footnote') return true;
  if (_hasClass(
    el,
    RegExp(
      r'duokan-footnote|noteref|footnote-ref|footnote-link|note-ref|sup-note',
      caseSensitive: false,
    ),
  )) {
    return true;
  }
  final fragment = href.split('#').last.toLowerCase();
  if (RegExp(
    r'^(fn|note|footnote|endnote|duokan[-_]?footnote|ref|n)[-_]?\d+',
  ).hasMatch(fragment)) {
    return true;
  }
  if (el.querySelector('sup, img.duokan-footnote, img.note') != null &&
      el.text.trim().length <= 8) {
    return true;
  }
  final text = el.text.trim();
  if (RegExp(r'^(\[\d+\]|〔\d+〕|（\d+）|\(\d+\)|[①-⑳]|\[注\d*\🌺?)$').hasMatch(text)) {
    return true;
  }
  return false;
}

/// Extracts all footnotes in `document` into a map and removes standalone
/// footnote definition containers from the main flow so they appear as popovers
/// rather than cluttering the end of the chapter.
Map<String, EpubFootnote> extractEpubFootnotes(
  html.Document document,
  Set<String> chapterBoundaryIds, {
  html.Element? Function(String href)? resolveExternalFootnoteTarget,
}) {
  final footnotes = <String, EpubFootnote>{};
  final toRemove = <html.Element>{};

  String cleanNoteText(html.Element el) {
    final clone = el.clone(true);
    for (final backlink in clone.querySelectorAll(
      'a[epub\\:type~="backlink"], a[role="doc-backlink"], a.footnote-backref, a.duokan-footnote-back, script, style',
    )) {
      backlink.remove();
    }
    for (final a in clone.querySelectorAll('a[href]')) {
      if (RegExp(r'^[↩↵↑^返回]+$').hasMatch(a.text.trim())) {
        a.remove();
      }
    }
    return clone.text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
  }

  for (final el in document.querySelectorAll('*')) {
    if (_isFootnoteDefinition(el)) {
      final id = el.id.isNotEmpty
          ? el.id
          : (el.attributes['name'] ??
                el.querySelector('[id]')?.id ??
                'fn-${footnotes.length + 1}');
      if (chapterBoundaryIds.contains(id)) continue;
      final content = cleanNoteText(el);
      if (content.isNotEmpty) {
        footnotes[id] = EpubFootnote(
          id: id,
          label: '注',
          content: content,
        );
        toRemove.add(el);
      }
    }
  }

  for (final a in document.querySelectorAll('a[href*="#"]')) {
    final href = a.attributes['href']!;
    final fragment = Uri.decodeComponent(href.split('#').last);
    if (fragment.isEmpty || chapterBoundaryIds.contains(fragment)) continue;
    final pathPart = href.split('#').first.trim();
    final sameDoc = pathPart.isEmpty;
    final target = sameDoc
        ? (document.getElementById(fragment) ??
              document.querySelector('[name="$fragment"]'))
        : (resolveExternalFootnoteTarget?.call(href) ??
              document.getElementById(fragment));
    final isNote =
        _isFootnoteLink(a) ||
        (target != null &&
            (_isFootnoteDefinition(target) ||
                (target.parent != null &&
                    _isFootnoteDefinition(target.parent!))));
    if (!isNote) continue;
    final label = a.text.replaceAll(RegExp(r'\s+'), '').trim();
    if (footnotes.containsKey(fragment)) {
      if (label.isNotEmpty && footnotes[fragment]!.label == '注') {
        footnotes[fragment] = EpubFootnote(
          id: fragment,
          label: label,
          content: footnotes[fragment]!.content,
        );
      }
      continue;
    }
    if (target == null) continue;
    // If target is an empty anchor `<a id="fn1"></a>` inside a `<p>` or `<li>`,
    // use the containing paragraph/list-item as the footnote body.
    final container = (target.localName == 'a' || target.localName == 'span') &&
            target.text.trim().isEmpty &&
            (target.parent?.localName == 'p' ||
                target.parent?.localName == 'li' ||
                target.parent?.localName == 'div' ||
                target.parent?.localName == 'aside')
        ? target.parent!
        : target;
    if (sameDoc && chapterBoundaryIds.contains(container.id)) continue;
    var content = cleanNoteText(container);
    if (label.isNotEmpty && content.startsWith(label)) {
      content = content.substring(label.length).trim();
    }
    if (content.isNotEmpty && content.length <= 8000) {
      footnotes[fragment] = EpubFootnote(
        id: fragment,
        label: label.isEmpty ? '注' : label,
        content: content,
      );
      if (sameDoc) {
        toRemove.add(container);
      }
    }
  }

  for (final el in toRemove) {
    el.remove();
  }
  return footnotes;
}

/// Computes an `EpubBlockStyle` for a DOM block element from its tag, classes,
/// and cascaded CSS declarations.
EpubBlockStyle buildEpubBlockStyle(
  html.Element element,
  Map<html.Element, Map<String, String>> elementProps, {
  String? listMarker,
  List<List<String>>? tableRows,
}) {
  final tag = element.localName ?? 'p';
  var kind = switch (tag) {
    'h1' => EpubBlockKind.heading1,
    'h2' => EpubBlockKind.heading2,
    'h3' => EpubBlockKind.heading3,
    'h4' => EpubBlockKind.heading4,
    'h5' => EpubBlockKind.heading5,
    'h6' => EpubBlockKind.heading6,
    'blockquote' => EpubBlockKind.blockquote,
    'pre' => EpubBlockKind.pre,
    'hr' => EpubBlockKind.hr,
    'li' => EpubBlockKind.listItem,
    'figcaption' => EpubBlockKind.figcaption,
    'table' => EpubBlockKind.table,
    'aside' => EpubBlockKind.callout,
    _ => EpubBlockKind.paragraph,
  };

  // Inspect element and ancestor classes/styles for Duokan & EPUB conventions.
  // Only CSS-inheritable typography properties are inherited from ancestor
  // containers (`div`, `section`, etc.); container box/border/break properties
  // are applied at the container boundary in `parseEpubDocumentChapters`.
  final mergedProps = <String, String>{};
  final ancestors = <html.Element>[];
  html.Element? cursor = element;
  while (cursor != null &&
      cursor.localName != 'body' &&
      cursor.localName != 'html') {
    ancestors.add(cursor);
    cursor = cursor.parent;
  }
  for (final node in ancestors.reversed) {
    if (elementProps[node] case final map?) {
      if (identical(node, element)) {
        mergedProps.addAll(map);
      } else {
        for (final entry in map.entries) {
          if (_inheritableCssProperties.contains(entry.key)) {
            mergedProps[entry.key] = entry.value;
          }
        }
      }
    }
    if (kind == EpubBlockKind.paragraph) {
      if (node.localName == 'blockquote' ||
          _hasClass(
            node,
            RegExp(
              r'blockquote|duokan-quote|quote|citation|epigraph|yinwen|yinyong',
              caseSensitive: false,
            ),
          )) {
        kind = EpubBlockKind.blockquote;
      } else if (node.localName == 'pre' ||
          _hasClass(
            node,
            RegExp(r'^pre$|code-block|poem|verse', caseSensitive: false),
          )) {
        kind = EpubBlockKind.pre;
      } else if (node.localName == 'figcaption' ||
          _hasClass(
            node,
            RegExp(
              r'duokan-image-maintitle|duokan-image-subtitle|figcaption|img-caption|image-caption|caption|pic-title|tuwen',
              caseSensitive: false,
            ),
          )) {
        kind = EpubBlockKind.figcaption;
      } else if (node.localName == 'aside' ||
          _hasClass(
            node,
            RegExp(
              r'duokan-callout|callout|infobox|info-box|box-note|note-box|card|frame|system-box|status-box|letter|message-box|tip-box|warning-box',
              caseSensitive: false,
            ),
          )) {
        kind = EpubBlockKind.callout;
      } else if (_hasClass(
        node,
        RegExp(
          r'duokan-maintitle|chapter-title|title-main|maintitle|ctitle|vtitle|vol-title|part-title|book-title|h1-title|^title$|^h1$|biaoti|zhangjie',
          caseSensitive: false,
        ),
      )) {
        kind = EpubBlockKind.heading1;
      } else if (_hasClass(
        node,
        RegExp(
          r'duokan-subtitle|chapter-subtitle|subtitle|sub-title|sec-title|section-title|h2-title|^h2$',
          caseSensitive: false,
        ),
      )) {
        kind = EpubBlockKind.heading2;
      } else if (_hasClass(
        node,
        RegExp(r'h3-title|^h3$', caseSensitive: false),
      )) {
        kind = EpubBlockKind.heading3;
      }
    }
  }

  var fontScale = _parseEmOrScale(mergedProps['font-size'])?.clamp(0.55, 2.4);
  if (fontScale != null && (fontScale - 1.0).abs() < 0.03) {
    fontScale = null;
  }
  final fontWeight = _parseFontWeight(mergedProps['font-weight']);
  final italic =
      mergedProps['font-style']?.toLowerCase().contains('italic') == true ||
      mergedProps['font-style']?.toLowerCase().contains('oblique') == true;
  final fontFamily = mergedProps['font-family'] == null
      ? null
      : _firstFontFamily(mergedProps['font-family']!);
  final textAlign = _parseTextAlign(mergedProps['text-align']);
  final textIndentEm = mergedProps.containsKey('text-indent')
      ? (_parseEmOrScale(mergedProps['text-indent']) ?? 0.0).clamp(0.0, 6.0)
      : null;

  double? lineHeight;
  if (mergedProps['line-height'] case final lhRaw?) {
    final s = lhRaw.trim().toLowerCase();
    if (s == 'normal' && fontScale != null && textIndentEm == 0) {
      // A publisher font shorthand resets leading as well as font size. Keep
      // its compact CJK default instead of inheriting the prose line height.
      lineHeight = 1.15;
    } else if (s != 'normal' && s != 'inherit' && s != 'initial') {
      if (s.endsWith('%')) {
        final v = double.tryParse(s.substring(0, s.length - 1));
        if (v != null) lineHeight = (v / 100.0).clamp(1.0, 3.0);
      } else {
        final v = _parseEmOrScale(s);
        if (v != null) lineHeight = v.clamp(1.0, 3.0);
      }
    }
  }
  // Ignore boilerplate `p { line-height: 1.125..1.35 }` on normal 1.0x body
  // paragraphs so user line-spacing preferences govern standard novel prose.
  if (kind == EpubBlockKind.paragraph &&
      fontScale == null &&
      lineHeight != null &&
      lineHeight <= 1.35) {
    lineHeight = null;
  }

  final letterSpacingEm = _parseEmOrScale(
    mergedProps['letter-spacing'],
  )?.clamp(-0.1, 1.0);

  // Flattened boxes are measured with the reader's base font. Resolve local
  // em lengths before combining them with their parent container's spacing.
  final margins = _parseBoxShorthand(
    mergedProps,
    'margin',
    emScale: fontScale ?? 1,
  );
  final paddings = _parseBoxShorthand(
    mergedProps,
    'padding',
    emScale: fontScale ?? 1,
  );
  final relativeInsets = <String, double>{};
  for (final prefix in ['margin', 'padding']) {
    final box = _parseBoxShorthand(mergedProps, prefix, percentages: true);
    for (final entry in {
      'top': box.top,
      'right': box.right,
      'bottom': box.bottom,
      'left': box.left,
    }.entries) {
      if (entry.value > 0) relativeInsets['$prefix-${entry.key}'] = entry.value;
    }
  }
  final horizPaddingEm = paddings.left > paddings.right
      ? paddings.left
      : paddings.right;

  final textColor = _parseCssColor(mergedProps['color']);
  final backgroundColor =
      _parseCssColor(mergedProps['background-color']) ??
      _parseCssColor(mergedProps['background']);

  final borderAll = _parseBorderSide(mergedProps['border']);
  final borderTop = _parseBorderSide(mergedProps['border-top']);
  final borderRight = _parseBorderSide(mergedProps['border-right']);
  final borderLeft = _parseBorderSide(mergedProps['border-left']);
  final borderBottom = _parseBorderSide(mergedProps['border-bottom']);

  var borderTopWidth = borderTop.width;
  if (mergedProps['border-top-width'] case final w?) {
    borderTopWidth = ((_parseEmOrScale(w) ?? 0) * 16).clamp(0.0, 18.0);
  }
  var borderLeftWidth = borderLeft.width > 0
      ? borderLeft.width
      : (kind == EpubBlockKind.blockquote && borderAll.width == 0 ? 3.0 : 0.0);
  if (mergedProps['border-left-width'] case final w?) {
    borderLeftWidth = ((_parseEmOrScale(w) ?? 0) * 16).clamp(0.0, 18.0);
  }
  var borderBottomWidth = borderBottom.width;
  if (mergedProps['border-bottom-width'] case final w?) {
    borderBottomWidth = ((_parseEmOrScale(w) ?? 0) * 16).clamp(0.0, 18.0);
  }
  var borderWidth = borderAll.width;
  if (borderWidth == 0 &&
      borderTopWidth > 0 &&
      borderBottomWidth > 0 &&
      (borderLeft.width > 0 || borderRight.width > 0)) {
    borderWidth = borderTopWidth;
  }
  if (mergedProps['border-width'] case final w?) {
    borderWidth = ((_parseEmOrScale(w) ?? 0) * 16).clamp(0.0, 18.0);
  }
  final rawBorderStyle =
      (mergedProps['border-style'] ??
              mergedProps['border-top-style'] ??
              mergedProps['border-bottom-style'] ??
              mergedProps['border-left-style'] ??
              borderTop.style ??
              borderBottom.style ??
              borderLeft.style ??
              borderAll.style ??
              '')
          .toLowerCase();
  String? resolvedBorderStyle;
  if (rawBorderStyle.contains('dotted')) {
    resolvedBorderStyle = 'dotted';
  } else if (rawBorderStyle.contains('dashed')) {
    resolvedBorderStyle = 'dashed';
  } else if (rawBorderStyle.contains('double')) {
    resolvedBorderStyle = 'double';
  } else if (rawBorderStyle.contains('solid')) {
    resolvedBorderStyle = 'solid';
  }
  if (borderWidth == 0 &&
      borderTopWidth == 0 &&
      borderBottomWidth == 0 &&
      borderLeftWidth == 0 &&
      (resolvedBorderStyle == 'solid' ||
          resolvedBorderStyle == 'dashed' ||
          resolvedBorderStyle == 'double' ||
          resolvedBorderStyle == 'dotted')) {
    borderWidth = 1.5;
  }
  final borderColor =
      _parseCssColor(mergedProps['border-top-color']) ??
      _parseCssColor(mergedProps['border-left-color']) ??
      _parseCssColor(mergedProps['border-bottom-color']) ??
      _parseCssColor(mergedProps['border-color']) ??
      borderTop.color ??
      borderLeft.color ??
      borderBottom.color ??
      borderAll.color;
  final borderRadius =
      ((_parseEmOrScale(mergedProps['border-radius']) ?? 0) * 16).clamp(
        0.0,
        24.0,
      );

  // Promote CSS-styled headings or boxed paragraphs automatically when semantic
  // tags/classes were omitted by the EPUB generator.
  if (kind == EpubBlockKind.paragraph) {
    final textLen = element.text.trim().length;
    if (fontScale != null && fontScale >= 1.35 && textLen > 0 && textLen <= 80) {
      kind = EpubBlockKind.heading1;
    } else if (fontScale != null &&
        fontScale >= 1.2 &&
        ((fontWeight ?? 400) >= 600 || textAlign == TextAlign.center) &&
        textLen > 0 &&
        textLen <= 80) {
      kind = EpubBlockKind.heading2;
    } else if (borderWidth > 0 || backgroundColor != null) {
      kind = EpubBlockKind.callout;
    } else if (borderLeftWidth >= 2.0 &&
        borderWidth == 0 &&
        borderTopWidth == 0 &&
        borderBottomWidth == 0) {
      kind = EpubBlockKind.blockquote;
    }
  }

  final isGalleryCell = _hasClass(
    element,
    RegExp(r'duokan-image-gallery-cell', caseSensitive: false),
  );
  final breakBeforeVal =
      (mergedProps['page-break-before'] ?? mergedProps['break-before'] ?? '')
          .toLowerCase();
  final breakAfterVal =
      (mergedProps['page-break-after'] ?? mergedProps['break-after'] ?? '')
          .toLowerCase();
  final pageBreakBefore =
      isGalleryCell ||
      breakBeforeVal == 'always' ||
      breakBeforeVal == 'page' ||
      breakBeforeVal == 'left' ||
      breakBeforeVal == 'right';
  final pageBreakAfter =
      isGalleryCell ||
      breakAfterVal == 'always' ||
      breakAfterVal == 'page' ||
      breakAfterVal == 'left' ||
      breakAfterVal == 'right';

  final hasBox =
      kind == EpubBlockKind.blockquote ||
      kind == EpubBlockKind.callout ||
      kind == EpubBlockKind.pre ||
      backgroundColor != null ||
      borderLeftWidth > 0 ||
      borderWidth > 0 ||
      borderTopWidth > 0 ||
      borderBottomWidth > 0 ||
      horizPaddingEm > 0 ||
      paddings.top > 0 ||
      paddings.bottom > 0 ||
      relativeInsets.keys.any((key) => key.startsWith('padding-'));
  var marginTopEm = margins.top;
  var marginBottomEm = margins.bottom;
  var marginLeftEm = margins.left;
  var marginRightEm = margins.right;
  final isFrontMatterParagraph =
      tag == 'p' &&
      ancestors.any(
        (node) => _hasClass(
          node,
          RegExp(r'^(info|intro|aupg)$', caseSensitive: false),
        ),
      );
  final horizontalBleed = ancestors.any(
    (node) =>
        (elementProps[node]?['duokan-bleed'] ?? '').toLowerCase() ==
        'leftright',
  );
  if (tag == 'p' &&
      kind == EpubBlockKind.paragraph &&
      !hasBox &&
      !isFrontMatterParagraph) {
    // Strip small symmetric page-bleed horizontal compensation (e.g. Duokan
    // `div.page-margin-no p { margin: 0.8em 0.5em 0.1em 0.5em }`) because the
    // reader already applies its own horizontal page margins.
    if (!horizontalBleed &&
        marginLeftEm > 0 &&
        marginRightEm > 0 &&
        marginLeftEm <= 0.8 &&
        marginRightEm <= 0.8 &&
        (marginLeftEm - marginRightEm).abs() < 0.05) {
      marginLeftEm = 0;
      marginRightEm = 0;
    }
    // Strip boilerplate paragraph vertical margins (e.g. `p { margin: 0.8em 0 0.1em 0 }`)
    // so the user's paragraph spacing slider controls normal body prose.
    if (textAlign != TextAlign.center &&
        textAlign != TextAlign.end &&
        textAlign != TextAlign.right &&
        marginTopEm <= 1.0 &&
        marginBottomEm <= 0.5) {
      marginTopEm = 0;
      marginBottomEm = 0;
    }
  }

  return EpubBlockStyle(
    kind: kind,
    horizontalBleed: horizontalBleed,
    fontScale: fontScale,
    fontWeight: fontWeight,
    italic: italic,
    fontFamily: fontFamily,
    textAlign: textAlign,
    textIndentEm: textIndentEm,
    lineHeight: lineHeight,
    letterSpacingEm: letterSpacingEm,
    marginTopEm: marginTopEm,
    marginBottomEm: marginBottomEm,
    marginLeftEm: marginLeftEm,
    marginRightEm: marginRightEm,
    paddingEm: horizPaddingEm > 0
        ? horizPaddingEm
        : (kind == EpubBlockKind.blockquote ||
                  kind == EpubBlockKind.callout ||
                  backgroundColor != null ||
                  borderWidth > 0)
        ? 0.65
        : 0.0,
    paddingTopEm: paddings.top,
    paddingBottomEm: paddings.bottom,
    separateVerticalPadding: true,
    relativeInsets: relativeInsets,
    ruleHeightEm: tag == 'hr' && mergedProps['height']?.endsWith('%') != true
        ? _parseEmOrScale(mergedProps['height'])
        : null,
    textColor: textColor,
    backgroundColor: backgroundColor,
    borderColor: borderColor,
    borderLeftWidth: borderLeftWidth,
    borderWidth: borderWidth,
    borderTopWidth: borderTopWidth,
    borderBottomWidth: borderBottomWidth,
    borderStyle: resolvedBorderStyle,
    borderRadius: borderRadius > 0
        ? borderRadius
        : (backgroundColor != null || borderWidth > 0 ? 8.0 : 0.0),
    pageBreakBefore: kind == EpubBlockKind.figcaption ? false : pageBreakBefore,
    pageBreakAfter: pageBreakAfter,
    listMarker: listMarker,
    tableRows: tableRows ?? const [],
  );
}

bool isDefaultParagraphStyle(EpubBlockStyle style) =>
    style.kind == EpubBlockKind.paragraph &&
    style.fontScale == null &&
    style.fontWeight == null &&
    !style.italic &&
    style.fontFamily == null &&
    style.textAlign == null &&
    (style.textIndentEm == null || style.textIndentEm == 2.0) &&
    style.lineHeight == null &&
    style.letterSpacingEm == null &&
    style.marginTopEm == 0 &&
    style.marginBottomEm == 0 &&
    style.blankLinesEm == 0 &&
    !style.lineBreakBefore &&
    !style.horizontalBleed &&
    style.imageGallery == null &&
    style.relativeInsets.isEmpty &&
    style.ruleHeightEm == null &&
    style.marginLeftEm == 0 &&
    style.marginRightEm == 0 &&
    style.paddingEm == 0 &&
    style.paddingTopEm == 0 &&
    style.paddingBottomEm == 0 &&
    style.textColor == null &&
    style.backgroundColor == null &&
    style.borderColor == null &&
    style.borderLeftWidth == 0 &&
    style.borderWidth == 0 &&
    style.borderTopWidth == 0 &&
    style.borderBottomWidth == 0 &&
    !style.pageBreakBefore &&
    !style.pageBreakAfter &&
    style.listMarker == null &&
    style.tableRows.isEmpty &&
    style.caption == null &&
    style.sideBySideImageUrls.isEmpty &&
    style.imageTapTargets.isEmpty &&
    style.floatRightWidthFraction == null;

class _InlineContext {
  const _InlineContext({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
    this.superscript = false,
    this.subscript = false,
    this.fontScale,
    this.fontFamily,
    this.textColor,
    this.backgroundColor,
    this.underlineColor,
    this.underlineStyle,
    this.underlineOffsetEm,
    this.underlinePaddingLeftEm = 0,
    this.underlinePaddingRightEm = 0,
    this.rubyText,
    this.footnoteId,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;
  final bool superscript;
  final bool subscript;
  final double? fontScale;
  final String? fontFamily;
  final int? textColor;
  final int? backgroundColor;
  final int? underlineColor;
  final String? underlineStyle;
  final double? underlineOffsetEm;
  final double underlinePaddingLeftEm;
  final double underlinePaddingRightEm;
  final String? rubyText;
  final String? footnoteId;

  bool get hasAny =>
      bold ||
      italic ||
      underline ||
      strike ||
      code ||
      superscript ||
      subscript ||
      fontScale != null ||
      fontFamily != null ||
      textColor != null ||
      backgroundColor != null ||
      underlineColor != null ||
      underlineStyle != null ||
      rubyText != null ||
      footnoteId != null;

  _InlineContext mergeElement(
    html.Element el,
    Map<String, String>? props, {
    String? rubyText,
    String? footnoteId,
  }) {
    final tag = el.localName ?? '';
    final weight = _parseFontWeight(props?['font-weight']);
    final isBold =
        bold ||
        tag == 'b' ||
        tag == 'strong' ||
        (weight != null && weight >= 600);
    final styleProp = props?['font-style']?.toLowerCase() ?? '';
    final isItalic =
        italic ||
        tag == 'i' ||
        tag == 'em' ||
        tag == 'cite' ||
        tag == 'dfn' ||
        styleProp.contains('italic') ||
        styleProp.contains('oblique');
    final decProp = props?['text-decoration']?.toLowerCase() ?? '';
    final borderBottom = _parseBorderSide(props?['border-bottom']);
    final hasBorderBottom =
        borderBottom.width > 0 ||
        ((_parseEmOrScale(props?['border-bottom-width']) ?? 0) > 0);
    final isUnderline =
        underline ||
        tag == 'u' ||
        tag == 'ins' ||
        decProp.contains('underline') ||
        hasBorderBottom;
    final uColor =
        _parseCssColor(props?['border-bottom-color']) ??
        borderBottom.color ??
        underlineColor;
    final uStyle =
        props?['border-bottom-style']?.toLowerCase() ??
        borderBottom.style ??
        underlineStyle;
    final borderPadding = hasBorderBottom
        ? _parseBoxShorthand(props ?? const {}, 'padding')
        : null;
    final uOffset = hasBorderBottom
        ? borderPadding!.bottom.clamp(0.18, 2.0)
        : underlineOffsetEm;
    final isStrike =
        strike ||
        tag == 's' ||
        tag == 'del' ||
        tag == 'strike' ||
        decProp.contains('line-through');
    final isCode =
        code || tag == 'code' || tag == 'kbd' || tag == 'samp' || tag == 'tt';
    final vAlign = props?['vertical-align']?.toLowerCase() ?? '';
    final mergedFootnoteId = footnoteId ?? this.footnoteId;
    final isRealFootnote =
        mergedFootnoteId != null &&
        !mergedFootnoteId.startsWith('epub-link:') &&
        !mergedFootnoteId.startsWith('epub-action:');
    final isSup =
        superscript ||
        tag == 'sup' ||
        vAlign == 'super' ||
        isRealFootnote;
    final isSub = subscript || tag == 'sub' || vAlign == 'sub';
    final scale =
        _parseEmOrScale(props?['font-size'])?.clamp(0.5, 2.2) ??
        (tag == 'small' ? 0.85 : fontScale);
    final family = props?['font-family'] != null
        ? _firstFontFamily(props!['font-family']!) ?? fontFamily
        : fontFamily;
    final color = _parseCssColor(props?['color']) ?? textColor;
    final bg =
        _parseCssColor(props?['background-color']) ??
        _parseCssColor(props?['background']) ??
        backgroundColor;

    return _InlineContext(
      bold: isBold,
      italic: isItalic,
      underline: isUnderline,
      strike: isStrike,
      code: isCode,
      superscript: isSup,
      subscript: isSub,
      fontScale: scale,
      fontFamily: family,
      textColor: color,
      backgroundColor: bg,
      underlineColor: uColor,
      underlineStyle: uStyle,
      underlineOffsetEm: uOffset,
      underlinePaddingLeftEm:
          borderPadding?.left.clamp(0.0, 2.0) ?? underlinePaddingLeftEm,
      underlinePaddingRightEm:
          borderPadding?.right.clamp(0.0, 2.0) ?? underlinePaddingRightEm,
      rubyText: rubyText ?? this.rubyText,
      footnoteId: footnoteId ?? this.footnoteId,
    );
  }
}

bool _elementHasSiblingText(html.Element img) {
  html.Element? block = img.parent;
  while (block != null &&
      !const {
        'p',
        'div',
        'section',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'blockquote',
        'li',
        'figcaption',
        'aside',
        'body',
      }.contains(block.localName)) {
    block = block.parent;
  }
  if (block == null ||
      block.localName == 'body' ||
      block.localName == 'section' ||
      block.localName == 'div') {
    // Direct child of body/div/section is only inline if inside an inline wrapper
    // like <a class="duokan-footnote"> that sits inside a text paragraph.
    return false;
  }
  return block.text.replaceAll(RegExp(r'\s+'), '').isNotEmpty;
}

bool _isFullPageImageElement(html.Element img) {
  if (img.localName == 'image') return true;
  html.Element? cursor = img;
  while (cursor != null && cursor.localName != 'body') {
    if (_hasClass(
      cursor,
      RegExp(
        r'duokan-fullscreen|fullpage|full-page|cover|illust',
        caseSensitive: false,
      ),
    )) {
      return true;
    }
    // The same Duokan wrapper is used for both plates and ordinary images
    // embedded in prose. Only a captioned plate implies its own page.
    if (_hasClass(
          cursor,
          RegExp(r'^duokan-image-single$', caseSensitive: false),
        ) &&
        cursor.querySelector('figcaption, .duokan-image-subtitle') != null) {
      return true;
    }
    cursor = cursor.parent;
  }
  return false;
}

/// Walks an EPUB XHTML `document` and invokes `onChapter` for each chapter
/// section split by `boundaries`.
void parseEpubDocumentChapters({
  required html.Document document,
  required String filePath,
  required Map<html.Element, LocalImageLayout> imageLayouts,
  required EpubStylesheetRules styleRules,
  required Map<String, EpubFootnote> footnotes,
  required Map<String, String> embeddedFonts,
  required ({String title, String volume})? initialLabel,
  required Map<String, ({String title, String volume})> boundaries,
  required String? Function(String src) resolveAndAddImage,
  required Iterable<String> Function(String text) splitBoundedParagraphs,
  required void Function(
    ({String title, String volume})? label,
    String? heading,
    List<String> paragraphs,
    EpubChapterLayout layout,
  ) onChapter,
  void Function(
    String origin,
    Map<String, ({int paragraph, int offset})> anchors,
  )? onChapterAnchors,
  String? Function(String href)? resolveLinkTarget,
  String? tocTargetKey,
  List<String> navColumnTargets = const [],
}) {
  var label = initialLabel;
  var origin = '$filePath#';
  final heading = document
      .querySelector(
        'h1, h2, h3, .duokan-maintitle, .chapter-title, .title-main, .ctitle',
      )
      ?.text
      .trim();
  final output = <String>[];
  final blocks = <int, EpubBlockStyle>{};
  final spans = <int, List<EpubInlineSpan>>{};
  final localAnchors = <String, ({int paragraph, int offset})>{
    origin: (paragraph: 0, offset: 0),
  };

  final textBuffer = StringBuffer();
  var currentSpans = <EpubInlineSpan>[];
  EpubBlockStyle? activeBlockStyle;
  var pendingBlankLinesEm = 0.0;

  void appendNormalizedText(String raw, _InlineContext inlineCtx) {
    if (raw.isEmpty) return;
    var normalized = raw.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
    if (textBuffer.isEmpty || textBuffer.toString().endsWith('\n')) {
      normalized = normalized.replaceFirst(RegExp(r'^[ \t\r\n]+'), '');
    } else if (textBuffer.toString().endsWith(' ') &&
        normalized.startsWith(' ')) {
      normalized = normalized.substring(1);
    }
    if (normalized.isEmpty) return;
    final start = textBuffer.length;
    textBuffer.write(normalized);
    final end = textBuffer.length;
    if (inlineCtx.hasAny && end > start) {
      currentSpans.add(
        EpubInlineSpan(
          start: start,
          end: end,
          bold: inlineCtx.bold,
          italic: inlineCtx.italic,
          underline: inlineCtx.underline,
          strike: inlineCtx.strike,
          code: inlineCtx.code,
          superscript: inlineCtx.superscript,
          subscript: inlineCtx.subscript,
          fontScale: inlineCtx.fontScale,
          fontFamily: inlineCtx.fontFamily,
          textColor: inlineCtx.textColor,
          backgroundColor: inlineCtx.backgroundColor,
          underlineColor: inlineCtx.underlineColor,
          underlineStyle: inlineCtx.underlineStyle,
          underlineOffsetEm: inlineCtx.underlineOffsetEm,
          underlinePaddingLeftEm: inlineCtx.underlinePaddingLeftEm,
          underlinePaddingRightEm: inlineCtx.underlinePaddingRightEm,
          rubyText: inlineCtx.rubyText,
          footnoteId: inlineCtx.footnoteId,
        ),
      );
    }
  }

  void flush({bool isLineBreak = false}) {
    var value = textBuffer.toString();
    value = value
        .replaceFirst(RegExp(r'^[ \t\r\n]+'), '')
        .replaceFirst(RegExp(r'[ \t\r\n]+$'), '');
    if (value.isNotEmpty) {
      var styleForEmit = isLineBreak && activeBlockStyle != null
          ? activeBlockStyle!.copyWith(
              marginBottomEm: 0,
              paddingBottomEm: 0,
              borderBottomWidth: 0,
              pageBreakAfter: false,
              relativeInsets: {
                for (final entry in activeBlockStyle!.relativeInsets.entries)
                  if (entry.key != 'margin-bottom' &&
                      entry.key != 'padding-bottom')
                    entry.key: entry.value,
              },
            )
          : activeBlockStyle;
      // A CSS inline border sits below the glyph box, rather than on the
      // font's underline metric (which can cross CJK glyphs).
      var borderPadding = 0.0;
      for (final span in currentSpans) {
        if (span.underlineOffsetEm case final offset?) {
          final padding =
              (offset + (styleForEmit?.isHeading == true ? 0.42 : 0.08)) *
              (span.fontScale ?? 1) *
              (styleForEmit?.effectiveScale ?? 1);
          if (padding > borderPadding) borderPadding = padding;
        }
      }
      if (borderPadding > 0) {
        final base = styleForEmit ?? const EpubBlockStyle();
        styleForEmit = base.copyWith(
          paddingBottomEm: base.effectivePaddingBottomEm > borderPadding
              ? base.effectivePaddingBottomEm
              : borderPadding,
        );
      }
      if (pendingBlankLinesEm > 0) {
        final base = styleForEmit ?? const EpubBlockStyle();
        styleForEmit = base.copyWith(
          blankLinesEm: base.blankLinesEm + pendingBlankLinesEm,
        );
        pendingBlankLinesEm = 0.0;
      }
      final parts = splitBoundedParagraphs(value).toList();
      var offset = 0;
      for (final part in parts) {
        final paragraphIndex = output.length;
        output.add(part);
        if (styleForEmit != null &&
            (!isDefaultParagraphStyle(styleForEmit) || isLineBreak)) {
          blocks[paragraphIndex] = offset == 0
              ? styleForEmit
              : styleForEmit.copyWith(
                  pageBreakBefore: false,
                  marginTopEm: 0,
                  paddingTopEm: 0,
                  borderTopWidth: 0,
                  listMarker: null,
                );
        }
        if (currentSpans.isNotEmpty) {
          final sliced = <EpubInlineSpan>[
            for (final s in currentSpans)
              if (s.slice(offset, offset + part.length) case final valid?)
                valid,
          ];
          if (sliced.isNotEmpty) {
            spans[paragraphIndex] = sliced;
          }
        }
        offset += part.length;
      }
      if (isLineBreak && activeBlockStyle != null) {
        activeBlockStyle = activeBlockStyle!.copyWith(
          pageBreakBefore: false,
          marginTopEm: 0,
          paddingTopEm: 0,
          borderTopWidth: 0,
          textIndentEm: 0,
          lineBreakBefore: true,
          relativeInsets: {
            for (final entry in activeBlockStyle!.relativeInsets.entries)
              if (entry.key != 'margin-top' && entry.key != 'padding-top')
                entry.key: entry.value,
          },
          listMarker: null,
        );
      }
    }
    textBuffer.clear();
    currentSpans = [];
  }

  void finishChapter() {
    flush();
    pendingBlankLinesEm = 0.0;
    onChapterAnchors?.call(
      origin,
      Map<String, ({int paragraph, int offset})>.of(localAnchors),
    );
    onChapter(
      label,
      heading,
      List<String>.of(output),
      EpubChapterLayout(
        blocks: Map<int, EpubBlockStyle>.of(blocks),
        spans: Map<int, List<EpubInlineSpan>>.of(spans),
        footnotes: footnotes,
        bodyFontFamily: styleRules.bodyFontFamily,
        embeddedFonts: embeddedFonts,
      ),
    );
    output.clear();
    blocks.clear();
    spans.clear();
    localAnchors.clear();
  }

  void visit(html.Node node, _InlineContext inlineCtx, {int? listIndex}) {
    if (node is html.Text) {
      appendNormalizedText(node.text, inlineCtx);
      return;
    }
    if (node is! html.Element) return;
    if (styleRules.elementProps[node]?['display']?.toLowerCase() == 'none' ||
        node.attributes.containsKey('hidden')) {
      return;
    }
    final idOrName = node.id.isNotEmpty ? node.id : node.attributes['name'];
    final boundary = idOrName == null ? null : boundaries[idOrName];
    if (boundary != null) {
      finishChapter();
      label = boundary;
      origin = '$filePath#$idOrName';
      localAnchors[origin] = (paragraph: 0, offset: 0);
    }
    if (idOrName != null &&
        idOrName.isNotEmpty &&
        localAnchors.length < 50000) {
      localAnchors['$filePath#$idOrName'] = (
        paragraph: output.length,
        offset: textBuffer.length,
      );
    }
    final tag = node.localName ?? '';

    if (tag == 'hr') {
      flush();
      if (idOrName != null &&
          idOrName.isNotEmpty &&
          localAnchors.length < 50000) {
        localAnchors['$filePath#$idOrName'] = (
          paragraph: output.length,
          offset: 0,
        );
      }
      final idx = output.length;
      output.add('───');
      blocks[idx] = buildEpubBlockStyle(node, styleRules.elementProps);
      return;
    }

    if (tag == 'table') {
      flush();
      if (idOrName != null &&
          idOrName.isNotEmpty &&
          localAnchors.length < 50000) {
        localAnchors['$filePath#$idOrName'] = (
          paragraph: output.length,
          offset: 0,
        );
      }
      if (node.querySelector('img, image') != null) {
        final tableStartIdx = output.length;
        for (final tr in node.querySelectorAll('tr')) {
          final trImgs = tr.querySelectorAll('img, image');
          if (trImgs.isNotEmpty) {
            flush();
            final urls = <String>[];
            for (final img in trImgs) {
              final src =
                  img.attributes['src'] ??
                  img.attributes['href'] ??
                  img.attributes.entries
                      .where((e) => e.key.toString() == 'xlink:href')
                      .firstOrNull
                      ?.value;
              if (src != null) {
                final u = resolveAndAddImage(src);
                if (u != null) urls.add(u);
              }
            }
            if (urls.isNotEmpty) {
              final idx = output.length;
              output.add('<!--image-->${urls.first}<!--image-->');
              final tableStyle = buildEpubBlockStyle(
                node,
                styleRules.elementProps,
              );
              blocks[idx] = EpubBlockStyle(
                pageBreakBefore:
                    idx == tableStartIdx || tableStyle.pageBreakBefore,
                horizontalBleed: tableStyle.horizontalBleed,
                marginTopEm: idx == tableStartIdx ? tableStyle.marginTopEm : 0,
                relativeInsets: {
                  if (idx == tableStartIdx &&
                      tableStyle.relativeInsets.containsKey('margin-top'))
                    'margin-top': tableStyle.relativeInsets['margin-top']!,
                },
                sideBySideImageUrls: urls.length >= 2 ? urls : const [],
              );
            }
            for (final cell in tr.children.where(
              (c) => c.localName == 'td' || c.localName == 'th',
            )) {
              for (final child in cell.nodes) {
                if (child is html.Element &&
                    child.localName != 'img' &&
                    child.localName != 'image' &&
                    child.querySelector('img, image') == null) {
                  visit(child, inlineCtx);
                }
              }
            }
            flush();
          } else {
            for (final cell in tr.children.where(
              (c) => c.localName == 'td' || c.localName == 'th',
            )) {
              for (final child in cell.nodes) {
                visit(child, inlineCtx);
              }
            }
            flush();
          }
        }
        if (output.length > tableStartIdx) {
          final firstIdx = tableStartIdx;
          final lastIdx = output.length - 1;
          final firstBase = blocks[firstIdx] ?? const EpubBlockStyle();
          blocks[firstIdx] = firstBase.copyWith(
            pageBreakBefore: true,
            pageBreakAfter: firstIdx == lastIdx,
          );
          if (lastIdx > firstIdx) {
            final lastBase = blocks[lastIdx] ?? const EpubBlockStyle();
            blocks[lastIdx] = lastBase.copyWith(pageBreakAfter: true);
          }
        }
        return;
      }
      final rows = <List<String>>[];
      for (final tr in node.querySelectorAll('tr')) {
        final cells = <String>[
          for (final cell in tr.children.where(
            (c) => c.localName == 'td' || c.localName == 'th',
          ))
            cell.text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
        ];
        if (cells.any((c) => c.isNotEmpty)) {
          rows.add(cells);
        }
      }
      if (rows.isNotEmpty) {
        final idx = output.length;
        output.add(rows.map((r) => r.join(' ｜ ')).join('\n'));
        blocks[idx] = buildEpubBlockStyle(
          node,
          styleRules.elementProps,
          tableRows: rows,
        );
      }
      return;
    }

    if (tag == 'ruby') {
      final baseBuffer = StringBuffer();
      final rtBuffer = StringBuffer();
      for (final child in node.nodes) {
        if (child is html.Text) {
          baseBuffer.write(child.text);
        } else if (child is html.Element) {
          if (child.localName == 'rt') {
            rtBuffer.write(child.text.trim());
          } else if (child.localName != 'rp') {
            baseBuffer.write(child.text);
          }
        }
      }
      final rt = rtBuffer.toString().trim();
      final nextCtx = inlineCtx.mergeElement(
        node,
        styleRules.elementProps[node],
        rubyText: rt.isEmpty ? null : rt,
      );
      appendNormalizedText(baseBuffer.toString(), nextCtx);
      return;
    }

    String? linkFootnoteId;
    if (tag == 'a' && node.attributes['href'] != null) {
      final href = node.attributes['href']!;
      if (href.contains('#')) {
        final frag = Uri.decodeComponent(href.split('#').last);
        if (footnotes.containsKey(frag)) {
          linkFootnoteId = frag;
        }
      }
      linkFootnoteId ??= resolveLinkTarget?.call(href);
    }
    if (linkFootnoteId == null &&
        inlineCtx.footnoteId == null &&
        _hasClass(node, RegExp(r'^nmb$', caseSensitive: false))) {
      linkFootnoteId = tocTargetKey != null
          ? 'epub-link:$tocTargetKey'
          : 'epub-action:toc';
    }

    if (tag == 'img' || tag == 'image') {
      final src =
          node.attributes['src'] ??
          node.attributes['href'] ??
          node.attributes.entries
              .where((e) => e.key.toString() == 'xlink:href')
              .firstOrNull
              ?.value;
      String? url;
      if (src != null) {
        url = resolveAndAddImage(src);
      }
      final effectiveFootnote = linkFootnoteId ?? inlineCtx.footnoteId;
      final isInlineNoteOrIcon =
          url != null &&
          tag == 'img' &&
          !_isFullPageImageElement(node) &&
          (effectiveFootnote != null || _elementHasSiblingText(node));
      if (isInlineNoteOrIcon) {
        final start = textBuffer.length;
        textBuffer.write('\uFFFC');
        currentSpans.add(
          EpubInlineSpan(
            start: start,
            end: start + 1,
            footnoteId: effectiveFootnote,
            inlineImageUrl: url,
            inlineImageLayout:
                imageLayouts[node] ??
                const LocalImageLayout(width: '1em', height: '1em'),
          ),
        );
        return;
      }
      flush();
      if (idOrName != null &&
          idOrName.isNotEmpty &&
          localAnchors.length < 50000) {
        localAnchors['$filePath#$idOrName'] = (
          paragraph: output.length,
          offset: 0,
        );
      }
      if (url != null) {
        final idx = output.length;
        output.add(
          '<!--image-->$url<!--image-->${imageLayouts[node]?.suffix ?? ''}',
        );
        final isNavImage =
            navColumnTargets.isNotEmpty &&
            node.parent != null &&
            _hasClass(
              node.parent!,
              RegExp(r'content-container', caseSensitive: false),
            );
        final parentProps = node.parent == null
            ? null
            : styleRules.elementProps[node.parent];
        final floatWidth = parentProps?['width']?.trim();
        final floatPercent = floatWidth != null && floatWidth.endsWith('%')
            ? double.tryParse(floatWidth.substring(0, floatWidth.length - 1))
            : null;
        final floatRightWidthFraction =
            parentProps?['float']?.trim().toLowerCase() == 'right' &&
                    floatPercent != null &&
                    floatPercent >= 25 &&
                    floatPercent <= 70
                ? floatPercent / 100
                : null;
        if (floatRightWidthFraction != null) {
          blocks[idx] = EpubBlockStyle(
            floatRightWidthFraction: floatRightWidthFraction,
          );
        } else if (_isFullPageImageElement(node)) {
          blocks[idx] = EpubBlockStyle(
            kind: EpubBlockKind.fullPageImage,
            pageBreakBefore: true,
            pageBreakAfter: true,
            imageTapTargets: isNavImage ? navColumnTargets : const [],
          );
        } else if (isNavImage) {
          blocks[idx] = EpubBlockStyle(
            kind: EpubBlockKind.fullPageImage,
            pageBreakBefore: true,
            pageBreakAfter: true,
            imageTapTargets: navColumnTargets,
          );
        }
      }
      return;
    }

    if (tag == 'br') {
      if (textBuffer.isEmpty) {
        if (output.isNotEmpty) {
          pendingBlankLinesEm = (pendingBlankLinesEm + 1.0).clamp(0.0, 4.0);
        }
      } else {
        flush(isLineBreak: true);
      }
      return;
    }

    const blockTags = {
      'p',
      'div',
      'section',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'blockquote',
      'pre',
      'li',
      'figcaption',
      'aside',
      'figure',
    };
    final isBlock = blockTags.contains(tag);
    final hasChildBlocks =
        isBlock &&
        node.children.any(
          (c) =>
              blockTags.contains(c.localName) ||
              c.localName == 'hr' ||
              c.localName == 'table' ||
              c.localName == 'img' ||
              c.localName == 'image',
        );
    final previousBlockStyle = activeBlockStyle;
    String? liMarker;
    EpubBlockStyle? containerStyle;
    var containerStartIdx = output.length;

    if (isBlock) {
      flush();
      containerStartIdx = output.length;
      if (idOrName != null &&
          idOrName.isNotEmpty &&
          localAnchors.length < 50000) {
        localAnchors['$filePath#$idOrName'] = (
          paragraph: containerStartIdx,
          offset: 0,
        );
      }
      liMarker = tag == 'li'
          ? (node.parent?.localName == 'ol'
                ? '${listIndex ?? 1}. '
                : '• ')
          : null;
      final computedStyle = buildEpubBlockStyle(
        node,
        styleRules.elementProps,
        listMarker: liMarker,
      );
      if (hasChildBlocks) {
        containerStyle = computedStyle;
        activeBlockStyle = previousBlockStyle;
      } else {
        activeBlockStyle = computedStyle;
      }
    }

    final nodeProps = styleRules.elementProps[node];
    final nextInlineCtx = isBlock
        ? (linkFootnoteId != null
              ? inlineCtx.mergeElement(node, null, footnoteId: linkFootnoteId)
              : inlineCtx)
        : inlineCtx.mergeElement(
            node,
            nodeProps,
            footnoteId: linkFootnoteId,
          );

    // Inline badges with background color and padding/margin (e.g. Duokan
    // `span.aul` for "作者" / "插画").
    var padInlineBadge = false;
    var inlineMarginRightEm = 0.0;
    if (!isBlock && nodeProps != null) {
      final inlinePaddings = _parseBoxShorthand(nodeProps, 'padding');
      final inlineMargins = _parseBoxShorthand(nodeProps, 'margin');
      if (nextInlineCtx.backgroundColor != null &&
          inlineCtx.backgroundColor == null &&
          (inlinePaddings.left > 0 || inlinePaddings.right > 0)) {
        padInlineBadge = true;
      }
      inlineMarginRightEm = inlineMargins.right;
    }

    if (linkFootnoteId != null &&
        node.text.trim().isEmpty &&
        node.querySelector('img, image') == null) {
      // A footnote link with no text or image still needs a tappable badge.
      final note = footnotes[linkFootnoteId];
      appendNormalizedText(note?.label ?? '[注]', nextInlineCtx);
    } else {
      if (liMarker != null &&
          node.querySelector('p, div, li') == null &&
          !RegExp(
            r'^([•·▪▸\-*]|\d+[.、)）])',
          ).hasMatch(node.text.trimLeft())) {
        appendNormalizedText(liMarker, const _InlineContext(bold: true));
      }
      if (padInlineBadge) {
        appendNormalizedText('\u00A0', nextInlineCtx);
      }
      var childLiIndex = 1;
      for (final child in node.nodes) {
        if (child is html.Element && child.localName == 'li') {
          visit(child, nextInlineCtx, listIndex: childLiIndex++);
        } else {
          visit(child, nextInlineCtx);
        }
      }
      if (padInlineBadge) {
        appendNormalizedText('\u00A0', nextInlineCtx);
      }
      if (inlineMarginRightEm >= 0.4) {
        appendNormalizedText('\u2003', inlineCtx);
      }
    }

    if (isBlock) {
      flush();
      if (containerStyle != null && output.length > containerStartIdx) {
        final firstIdx = containerStartIdx;
        final lastIdx = output.length - 1;
        final isImageFigureContainer =
            lastIdx > firstIdx &&
            output[firstIdx].startsWith('<!--image-->') &&
            blocks[lastIdx]?.kind == EpubBlockKind.figcaption;
        EpubBlockStyle insideContainerBorder(EpubBlockStyle base) {
          // A child's horizontal margin sits inside its parent's top/bottom
          // rule. Moving symmetric margins into padding keeps the rule wide.
          if ((containerStyle!.borderTopWidth > 0 ||
                  containerStyle.borderBottomWidth > 0 ||
                  containerStyle.borderWidth > 0) &&
              base.marginLeftEm > 0 &&
              base.marginLeftEm == base.marginRightEm) {
            return base.copyWith(
              paddingEm: base.paddingEm + base.marginLeftEm,
              marginLeftEm: 0,
              marginRightEm: 0,
            );
          }
          return base;
        }
        final firstBase = insideContainerBorder(
          blocks[firstIdx] ?? const EpubBlockStyle(),
        );
        final containsTopMargin =
            containerStyle.effectivePaddingTopEm > 0 ||
            containerStyle.borderTopWidth > 0 ||
            containerStyle.borderWidth > 0 ||
            (containerStyle.relativeInsets['padding-top'] ?? 0) > 0;
        final containsBottomMargin =
            containerStyle.effectivePaddingBottomEm > 0 ||
            containerStyle.borderBottomWidth > 0 ||
            containerStyle.borderWidth > 0 ||
            (containerStyle.relativeInsets['padding-bottom'] ?? 0) > 0;
        Map<String, double> boundaryInsets(
          EpubBlockStyle base,
          String side,
          bool contained,
        ) {
          final margin = 'margin-$side', padding = 'padding-$side';
          final childMargin = base.relativeInsets[margin] ?? 0;
          return {
            ...base.relativeInsets,
            margin: contained
                ? (containerStyle!.relativeInsets[margin] ?? 0)
                : side == 'top' && containerStyle!.pageBreakBefore
                ? childMargin + (containerStyle.relativeInsets[margin] ?? 0)
                : math.max(
                    childMargin,
                    containerStyle!.relativeInsets[margin] ?? 0,
                  ),
            padding:
                (base.relativeInsets[padding] ?? 0) +
                (containerStyle.relativeInsets[padding] ?? 0) +
                (contained ? childMargin : 0),
          }..removeWhere((_, value) => value == 0);
        }

        final updatedFirst = firstBase.copyWith(
          pageBreakBefore:
              firstBase.pageBreakBefore || containerStyle.pageBreakBefore,
          pageBreakAfter: isImageFigureContainer
              ? false
              : firstBase.pageBreakAfter,
          marginTopEm: containsTopMargin
              ? containerStyle.marginTopEm
              // Forced page boundaries keep the first child's margin inside
              // its page instead of collapsing it through the container.
              : containerStyle.pageBreakBefore
              ? firstBase.marginTopEm + containerStyle.marginTopEm
              : math.max(firstBase.marginTopEm, containerStyle.marginTopEm),
          paddingTopEm:
              firstBase.effectivePaddingTopEm +
              containerStyle.effectivePaddingTopEm +
              (containsTopMargin ? firstBase.marginTopEm : 0),
          relativeInsets: boundaryInsets(firstBase, 'top', containsTopMargin),
          borderTopWidth: firstBase.borderTopWidth > 0
              ? firstBase.borderTopWidth
              : containerStyle.borderTopWidth,
          borderStyle: firstBase.borderStyle ?? containerStyle.borderStyle,
          borderColor: firstBase.borderColor ?? containerStyle.borderColor,
        );
        if (!isDefaultParagraphStyle(updatedFirst)) {
          blocks[firstIdx] = updatedFirst;
        }
        final lastBase = insideContainerBorder(
          blocks[lastIdx] ?? const EpubBlockStyle(),
        );
        final updatedLast = lastBase.copyWith(
          pageBreakAfter:
              isImageFigureContainer ||
              lastBase.pageBreakAfter ||
              containerStyle.pageBreakAfter,
          marginBottomEm: containsBottomMargin
              ? containerStyle.marginBottomEm
              : math.max(
                  lastBase.marginBottomEm,
                  containerStyle.marginBottomEm,
                ),
          paddingBottomEm:
              lastBase.effectivePaddingBottomEm +
              containerStyle.effectivePaddingBottomEm +
              (containsBottomMargin ? lastBase.marginBottomEm : 0),
          relativeInsets: boundaryInsets(
            lastBase,
            'bottom',
            containsBottomMargin,
          ),
          borderBottomWidth: lastBase.borderBottomWidth > 0
              ? lastBase.borderBottomWidth
              : containerStyle.borderBottomWidth,
          borderStyle: lastBase.borderStyle ?? containerStyle.borderStyle,
          borderColor: lastBase.borderColor ?? containerStyle.borderColor,
        );
        if (!isDefaultParagraphStyle(updatedLast)) {
          blocks[lastIdx] = updatedLast;
        }
        if (containerStyle.horizontalBleed ||
            containerStyle.relativeInsets.keys.any(
              (key) => key.endsWith('-left') || key.endsWith('-right'),
            ) ||
            containerStyle.marginLeftEm > 0 ||
            containerStyle.marginRightEm > 0 ||
            containerStyle.paddingEm > 0 ||
            containerStyle.borderLeftWidth > 0 ||
            containerStyle.borderWidth > 0 ||
            containerStyle.backgroundColor != null) {
          for (var i = firstIdx; i <= lastIdx; i++) {
            final base = blocks[i] ?? const EpubBlockStyle();
            final updated = base.copyWith(
              horizontalBleed:
                  base.horizontalBleed || containerStyle.horizontalBleed,
              marginLeftEm: base.marginLeftEm + containerStyle.marginLeftEm,
              marginRightEm: base.marginRightEm + containerStyle.marginRightEm,
              relativeInsets: {
                ...base.relativeInsets,
                for (final edge in [
                  'margin-left',
                  'margin-right',
                  'padding-left',
                  'padding-right',
                ])
                  if ((base.relativeInsets[edge] ?? 0) +
                          (containerStyle.relativeInsets[edge] ?? 0) >
                      0)
                    edge:
                        (base.relativeInsets[edge] ?? 0) +
                        (containerStyle.relativeInsets[edge] ?? 0),
              },
              paddingEm: base.paddingEm > 0
                  ? base.paddingEm
                  : containerStyle.paddingEm,
              paddingTopEm: base.effectivePaddingTopEm,
              paddingBottomEm: base.effectivePaddingBottomEm,
              separateVerticalPadding: true,
              borderLeftWidth: math.max(
                base.borderLeftWidth,
                containerStyle.borderLeftWidth,
              ),
              borderWidth: base.borderWidth > 0
                  ? base.borderWidth
                  : containerStyle.borderWidth,
              backgroundColor:
                  base.backgroundColor ?? containerStyle.backgroundColor,
              borderColor: base.borderColor ?? containerStyle.borderColor,
              borderStyle: base.borderStyle ?? containerStyle.borderStyle,
            );
            if (!isDefaultParagraphStyle(updated)) {
              blocks[i] = updated;
            }
          }
        }
      }
      activeBlockStyle = previousBlockStyle;
      if (node.classes.contains('duokan-image-gallery')) {
        final members = [
          for (var i = containerStartIdx; i < output.length; i++) i,
        ];
        final images = members.where(
          (i) => output[i].startsWith('<!--image-->'),
        );
        // Leave unusual galleries containing prose to the ordinary renderer.
        if (images.length > 1 &&
            members.every(
              (i) =>
                  output[i].startsWith('<!--image-->') ||
                  blocks[i]?.kind == EpubBlockKind.figcaption,
            )) {
          final owner = images.first;
          for (final i in members) {
            blocks[i] = (blocks[i] ?? const EpubBlockStyle()).copyWith(
              imageGallery: owner,
              pageBreakBefore: i == owner,
              pageBreakAfter: i == owner,
            );
          }
        }
      }
    }
  }

  final body = document.body;
  if (body != null) {
    visit(body, const _InlineContext());
  }
  finishChapter();
}

