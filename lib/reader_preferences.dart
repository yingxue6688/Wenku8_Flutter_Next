import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'archive_design.dart';
import 'personal_images.dart' show validBackgroundId;

const minimumReaderFontSize = 10.0;
const maximumReaderFontSize = 27.0;
const maximumReaderCustomPalettes = 100;
const maximumReaderCustomPaletteNameLength = 40;

enum ReaderPaper {
  system('跟随外观'),
  milk('奶白'),
  parchment('羊皮纸'),
  sage('浅苔'),
  night('夜读'),
  custom('自定义');

  const ReaderPaper(this.label);
  final String label;
}

bool _validReaderCustomPaletteId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 80 &&
    !RegExp(r'[^A-Za-z0-9_-]').hasMatch(value);

@immutable
class ReaderCustomPalette {
  const ReaderCustomPalette({
    required this.id,
    required this.name,
    required this.background,
    required this.foreground,
  });

  final String id, name;
  final Color background, foreground;

  ReaderCustomPalette copyWith({
    String? id,
    String? name,
    Color? background,
    Color? foreground,
  }) => ReaderCustomPalette(
    id: id ?? this.id,
    name: name ?? this.name,
    background: background ?? this.background,
    foreground: foreground ?? this.foreground,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'background': background.toARGB32(),
    'foreground': foreground.toARGB32(),
  };

  factory ReaderCustomPalette.fromJson(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'];
    if (!_validReaderCustomPaletteId(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > maximumReaderCustomPaletteNameLength ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('自定义阅读配色名称或标识有误');
    }
    Color color(String key) {
      final value = json[key];
      if (value is! int || value < 0xFF000000 || value > 0xFFFFFFFF) {
        throw const FormatException('自定义阅读配色必须是不透明颜色');
      }
      return Color(value);
    }

    return ReaderCustomPalette(
      id: id as String,
      name: name,
      background: color('background'),
      foreground: color('foreground'),
    );
  }
}

enum ReaderMode {
  scroll('上下滚动'),
  paged('横排翻页'),
  vertical('竖排翻页');

  const ReaderMode(this.label);
  final String label;
  bool get paginated => this != scroll;
}

enum ReaderVerticalLatinOrientation {
  rotated('随文旋转'),
  upright('逐字直立');

  const ReaderVerticalLatinOrientation(this.label);
  final String label;
}

/// Stored layout keys may also carry typography and content-filter suffixes.
/// Read the mode token rather than requiring it to be the last field.
bool readerLayoutIsPaginated(String layout) => layout
    .split('|')
    .any(
      (section) =>
          !section.startsWith('languages=') &&
          section
              .split(':')
              .any((part) => part == 'paged' || part == 'vertical'),
    );

enum ReaderTapLayout {
  standard('常规'),
  rightHand('右手'),
  leftHand('左手');

  const ReaderTapLayout(this.label);
  final String label;
}

enum ReaderPageEffect {
  staggered('段落接续'),
  none('无动画'),
  slide('平移'),
  cover('覆盖'),
  paper('纸页翻动'),
  fade('渐隐');

  const ReaderPageEffect(this.label);
  final String label;
  Duration get duration => switch (this) {
    staggered => const Duration(milliseconds: 620),
    none => Duration.zero,
    slide => const Duration(milliseconds: 300),
    cover => const Duration(milliseconds: 340),
    paper => const Duration(milliseconds: 440),
    fade => const Duration(milliseconds: 300),
  };
}

enum ReaderPageSpeed {
  relaxed('舒缓', 1.35),
  normal('标准', 1),
  quick('利落', .7);

  const ReaderPageSpeed(this.label, this.durationScale);
  final String label;
  final double durationScale;

  Duration durationFor(ReaderPageEffect effect) => Duration(
    microseconds: (effect.duration.inMicroseconds * durationScale).round(),
  );
}

enum ReaderTextWeight {
  regular('常规', FontWeight.w400),
  medium('适中', FontWeight.w500),
  bold('加粗', FontWeight.w600);

  const ReaderTextWeight(this.label, this.weight);
  final String label;
  final FontWeight weight;
}

const maximumReaderInfoTemplateLength = 160;
const defaultReaderHeaderLeft = '{时间}';
const defaultReaderHeaderMiddle = '';
const defaultReaderHeaderRight = '{电量图标数值}';
const defaultReaderFooterLeft = '{章节}';
const defaultReaderFooterMiddle = '';
const defaultReaderFooterRight = '{页码} / {总页数} 页 · {阅读进度}';

enum ReaderBarVisibility {
  hideWhenStatusShown('状态栏显示时隐藏'),
  show('显示'),
  hide('隐藏');

  const ReaderBarVisibility(this.label);
  final String label;
}

enum ReaderInfoDividerMode {
  hidden('隐藏'),
  inherit('默认'),
  custom('自定义');

  const ReaderInfoDividerMode(this.label);
  final String label;
}

/// Reader-only settings: changing paper never changes the rest of the app.
class ReaderPreferences {
  const ReaderPreferences({
    this.paper = ReaderPaper.system,
    this.customPalettes = const [],
    this.customPaletteId,
    this.margin = 26,
    this.marginLeft,
    this.marginRight,
    this.marginTop = 8,
    this.marginBottom = 8,
    this.paragraphGap = 12,
    this.paragraphGapOverride = false,
    this.catalogueReversed = false,
    this.indent = false,
    this.justify = false,
    this.tapPaging = false,
    this.tapBothSidesNext = false,
    this.volumePaging = false,
    this.brightness,
    this.autoScrollSpeed = 24,
    this.mode = ReaderMode.scroll,
    this.verticalLatinOrientation = ReaderVerticalLatinOrientation.rotated,
    this.tapLayout = ReaderTapLayout.standard,
    this.edgeBrightness = false,
    this.pageEffect = ReaderPageEffect.staggered,
    this.pageSpeed = ReaderPageSpeed.normal,
    this.hideSystemStatus = false,
    this.showStatusInfo = true,
    this.headerVisibility = ReaderBarVisibility.hideWhenStatusShown,
    this.footerVisibility = ReaderBarVisibility.show,
    this.headerLeft = defaultReaderHeaderLeft,
    this.headerMiddle = defaultReaderHeaderMiddle,
    this.headerRight = defaultReaderHeaderRight,
    this.footerLeft = defaultReaderFooterLeft,
    this.footerMiddle = defaultReaderFooterMiddle,
    this.footerRight = defaultReaderFooterRight,
    this.infoTextColor,
    this.infoDividerMode = ReaderInfoDividerMode.hidden,
    this.infoDividerColor,
    this.chapterEntrance = false,
    this.nightTextBrightness = .82,
    this.letterSpacing = .1,
    this.textWeight = ReaderTextWeight.regular,
    this.statusFontSize = 12,
    this.headerMarginTop = 0,
    this.headerMarginBottom = 0,
    this.headerMarginLeft,
    this.headerMarginRight,
    this.footerMarginTop = 0,
    this.footerMarginBottom = 0,
    this.footerMarginLeft,
    this.footerMarginRight,
    this.backgroundImage,
    this.backgroundOpacity = .18,
    this.backgroundFit = BoxFit.cover,
  });
  final ReaderPaper paper;
  final List<ReaderCustomPalette> customPalettes;
  final String? customPaletteId;
  ReaderCustomPalette? get customPalette {
    for (final palette in customPalettes) {
      if (palette.id == customPaletteId) return palette;
    }
    return customPalettes.firstOrNull;
  }

  final double margin, paragraphGap, autoScrollSpeed;
  final bool paragraphGapOverride, catalogueReversed;
  // Null horizontal edges preserve old records and existing margin callers.
  final double? marginLeft, marginRight;
  final double marginTop, marginBottom;
  double get leftMargin => marginLeft ?? margin;
  double get rightMargin => marginRight ?? margin;
  double get bindingMargin => (leftMargin + rightMargin) / 2;
  final bool indent, justify, tapPaging, tapBothSidesNext, volumePaging;
  final double? brightness;
  final ReaderMode mode;
  final ReaderVerticalLatinOrientation verticalLatinOrientation;
  final ReaderTapLayout tapLayout;
  final bool edgeBrightness;
  final ReaderPageEffect pageEffect;
  final ReaderPageSpeed pageSpeed;
  final bool hideSystemStatus;
  final bool showStatusInfo;
  final ReaderBarVisibility headerVisibility;
  final ReaderBarVisibility footerVisibility;
  final String headerLeft, headerMiddle, headerRight;
  final String footerLeft, footerMiddle, footerRight;
  final Color? infoTextColor;
  final ReaderInfoDividerMode infoDividerMode;
  final Color? infoDividerColor;
  bool get showReaderStatus => showsHeader && hideSystemStatus;
  bool get showsHeader => switch (headerVisibility) {
    ReaderBarVisibility.hideWhenStatusShown => hideSystemStatus,
    ReaderBarVisibility.show => true,
    ReaderBarVisibility.hide => false,
  };
  bool get showsFooter => switch (footerVisibility) {
    ReaderBarVisibility.hideWhenStatusShown => hideSystemStatus,
    ReaderBarVisibility.show => true,
    ReaderBarVisibility.hide => false,
  };
  Object get infoLayoutSignature => (
    hideSystemStatus,
    showsHeader,
    showsFooter,
    headerMiddle.trim().isEmpty,
    infoDividerMode != ReaderInfoDividerMode.hidden,
    statusFontSize,
    headerMarginTop,
    headerMarginBottom,
    footerMarginTop,
    footerMarginBottom,
  );
  final bool chapterEntrance;
  final double nightTextBrightness;
  final double letterSpacing;
  final ReaderTextWeight textWeight;
  final double statusFontSize;
  final double headerMarginTop, headerMarginBottom;
  final double? headerMarginLeft, headerMarginRight;
  final double footerMarginTop, footerMarginBottom;
  final double? footerMarginLeft, footerMarginRight;
  double get effectiveHeaderMarginLeft => headerMarginLeft ?? leftMargin;
  double get effectiveHeaderMarginRight => headerMarginRight ?? rightMargin;
  double get effectiveFooterMarginLeft => footerMarginLeft ?? leftMargin;
  double get effectiveFooterMarginRight => footerMarginRight ?? rightMargin;
  final String? backgroundImage;
  final double backgroundOpacity;
  final BoxFit backgroundFit;
  String get layoutKey {
    final geometry =
        leftMargin == 26 &&
            rightMargin == 26 &&
            marginTop == 8 &&
            marginBottom == 8 &&
            paragraphGap == 12 &&
            !indent &&
            !justify &&
            mode == ReaderMode.scroll
        ? ''
        : '${leftMargin == rightMargin && marginTop == 8 && marginBottom == 8 ? '$leftMargin' : '$leftMargin,$marginTop,$rightMargin,$marginBottom'}:$paragraphGap:$indent:$justify';
    final modeKey = mode == ReaderMode.scroll ? '' : ':${mode.name}';
    final gapKey = paragraphGapOverride ? ':gap=custom' : '';
    final textKey =
        letterSpacing == .1 && textWeight == ReaderTextWeight.regular
        ? ''
        : ':text=$letterSpacing,${textWeight.name}';
    if (mode == ReaderMode.vertical &&
        verticalLatinOrientation == ReaderVerticalLatinOrientation.upright) {
      return '$geometry$gapKey$textKey:latin=upright$modeKey';
    }
    // Existing preferences retain exactly the same persisted layout key.
    return '$geometry$gapKey$modeKey$textKey';
  }

  Color background(bool dark) => switch (paper) {
    ReaderPaper.system =>
      dark ? ArchiveDesign.darkBackground : const Color(0xFFF7F7F2),
    ReaderPaper.milk => const Color(0xFFF6F5EF),
    ReaderPaper.parchment => const Color(0xFFEDE2CA),
    ReaderPaper.sage => const Color(0xFFE4EBDD),
    ReaderPaper.night => ArchiveDesign.darkBackground,
    ReaderPaper.custom => customPalette?.background ?? const Color(0xFFF6F5EF),
  };
  Color controlForeground(bool dark) =>
      darkPaper(dark) ? ArchiveDesign.darkInk : const Color(0xFF30352F);
  bool darkPaper(bool dark) => paper == ReaderPaper.custom
      ? ThemeData.estimateBrightnessForColor(background(dark)) ==
            Brightness.dark
      : paper == ReaderPaper.night || paper == ReaderPaper.system && dark;
  Color foreground(bool dark) => paper == ReaderPaper.custom
      ? customPalette?.foreground ?? const Color(0xFF30352F)
      : darkPaper(dark)
      ? Color.lerp(
          background(dark),
          controlForeground(dark),
          nightTextBrightness,
        )!
      : controlForeground(dark);
  Color effectiveInfoColor(bool dark) =>
      infoTextColor ?? controlForeground(dark).withValues(alpha: .72);
  Color? effectiveDividerColor(bool dark) => switch (infoDividerMode) {
    ReaderInfoDividerMode.hidden => null,
    ReaderInfoDividerMode.inherit => effectiveInfoColor(dark).withValues(
      alpha: .28,
    ),
    ReaderInfoDividerMode.custom =>
      infoDividerColor ?? effectiveInfoColor(dark).withValues(alpha: .28),
  };
  Map<String, Object?> toJson() => {
    'paper': paper.name,
    if (customPalettes.isNotEmpty)
      'customPalettes': [
        for (final palette in customPalettes) palette.toJson(),
      ],
    if (customPaletteId != null) 'customPaletteId': customPaletteId,
    'margin': margin,
    if (marginLeft != null) 'marginLeft': marginLeft,
    if (marginRight != null) 'marginRight': marginRight,
    'marginTop': marginTop,
    'marginBottom': marginBottom,
    'paragraphGap': paragraphGap,
    if (paragraphGapOverride || paragraphGap != 12)
      'paragraphGapOverride': paragraphGapOverride,
    if (catalogueReversed) 'catalogueReversed': true,
    'indent': indent,
    'justify': justify,
    'tapPaging': tapPaging,
    'tapBothSidesNext': tapBothSidesNext,
    'volumePaging': volumePaging,
    'brightness': brightness,
    'autoScrollSpeed': autoScrollSpeed,
    'mode': mode.name,
    'verticalLatinOrientation': verticalLatinOrientation.name,
    'tapLayout': tapLayout.name,
    'edgeBrightness': edgeBrightness,
    'pageEffect': pageEffect.name,
    'pageSpeed': pageSpeed.name,
    'hideSystemStatus': hideSystemStatus,
    'showStatusInfo': showStatusInfo,
    'headerVisibility': headerVisibility.name,
    'footerVisibility': footerVisibility.name,
    'headerLeft': headerLeft,
    'headerMiddle': headerMiddle,
    'headerRight': headerRight,
    'footerLeft': footerLeft,
    'footerMiddle': footerMiddle,
    'footerRight': footerRight,
    if (infoTextColor != null) 'infoTextColor': infoTextColor!.toARGB32(),
    'infoDividerMode': infoDividerMode.name,
    if (infoDividerColor != null)
      'infoDividerColor': infoDividerColor!.toARGB32(),
    'chapterEntrance': chapterEntrance,
    'nightTextBrightness': nightTextBrightness,
    'letterSpacing': letterSpacing,
    'textWeight': textWeight.name,
    'statusFontSize': statusFontSize,
    'headerMarginTop': headerMarginTop,
    'headerMarginBottom': headerMarginBottom,
    if (headerMarginLeft != null) 'headerMarginLeft': headerMarginLeft,
    if (headerMarginRight != null) 'headerMarginRight': headerMarginRight,
    'footerMarginTop': footerMarginTop,
    'footerMarginBottom': footerMarginBottom,
    if (footerMarginLeft != null) 'footerMarginLeft': footerMarginLeft,
    if (footerMarginRight != null) 'footerMarginRight': footerMarginRight,
    if (backgroundImage != null) 'backgroundImage': backgroundImage,
    'backgroundOpacity': backgroundOpacity,
    'backgroundFit': backgroundFit.name,
  };
  factory ReaderPreferences.fromJson(Map<String, dynamic> json) {
    double number(String key, double min, double max, double fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! num || !value.isFinite || value < min || value > max) {
        throw const FormatException('阅读偏好数值超出范围');
      }
      return value.toDouble();
    }

    for (final key in [
      'indent',
      'justify',
      'tapPaging',
      'tapBothSidesNext',
      'volumePaging',
      'edgeBrightness',
      'hideSystemStatus',
      'showStatusInfo',
      'chapterEntrance',
      'paragraphGapOverride',
      'catalogueReversed',
    ]) {
      if (json[key] != null && json[key] is! bool) {
        throw const FormatException('阅读偏好格式有误');
      }
    }
    if (json['backgroundImage'] != null &&
        !validBackgroundId(json['backgroundImage'])) {
      throw const FormatException('阅读背景记录有误');
    }
    final palettes = json['customPalettes'] ?? const [];
    final paletteId = json['customPaletteId'];
    if (palettes is! List ||
        palettes.length > maximumReaderCustomPalettes ||
        paletteId != null && !_validReaderCustomPaletteId(paletteId)) {
      throw const FormatException('自定义阅读配色记录有误');
    }
    final customPalettes = <ReaderCustomPalette>[];
    final paletteIds = <String>{};
    for (final record in palettes) {
      if (record is! Map<String, dynamic>) {
        throw const FormatException('自定义阅读配色记录有误');
      }
      final palette = ReaderCustomPalette.fromJson(record);
      if (!paletteIds.add(palette.id)) {
        throw const FormatException('自定义阅读配色标识重复');
      }
      customPalettes.add(palette);
    }
    String template(String key, String fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! String ||
          value.length > maximumReaderInfoTemplateLength ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('页眉或页脚模板格式有误');
      }
      return value;
    }

    Color? colorOrNull(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! int || value < 0xFF000000 || value > 0xFFFFFFFF) {
        throw const FormatException('页眉或页脚颜色格式有误');
      }
      return Color(value);
    }

    final legacyShowStatus = json['showStatusInfo'] != false;
    final parsedHeaderVisibility = json['headerVisibility'] == null
        ? (legacyShowStatus
              ? ReaderBarVisibility.hideWhenStatusShown
              : ReaderBarVisibility.hide)
        : ReaderBarVisibility.values.byName(json['headerVisibility'] as String);
    final parsedFooterVisibility = json['footerVisibility'] == null
        ? ReaderBarVisibility.show
        : ReaderBarVisibility.values.byName(json['footerVisibility'] as String);
    final parsedDividerMode = json['infoDividerMode'] == null
        ? ReaderInfoDividerMode.hidden
        : ReaderInfoDividerMode.values.byName(
            json['infoDividerMode'] as String,
          );
    final parsedMargin = number('margin', 0, 80, 26);
    final parsedMarginLeft = json['marginLeft'] == null
        ? null
        : number('marginLeft', 0, 80, 26);
    final parsedMarginRight = json['marginRight'] == null
        ? null
        : number('marginRight', 0, 80, 26);
    final legacyTopOffset = json['statusTopOffset'] == null
        ? 0.0
        : number('statusTopOffset', -8, 24, 0);
    final legacySideInset = json['statusSideInset'] == null
        ? 0.0
        : number('statusSideInset', 0, 96, 0);
    final baseLeft = parsedMarginLeft ?? parsedMargin;
    final baseRight = parsedMarginRight ?? parsedMargin;
    return ReaderPreferences(
      paper: ReaderPaper.values.firstWhere(
        (p) => p.name == (json['paper'] ?? 'system'),
      ),
      customPalettes: List.unmodifiable(customPalettes),
      customPaletteId: paletteId as String?,
      margin: parsedMargin,
      marginLeft: parsedMarginLeft,
      marginRight: parsedMarginRight,
      marginTop: number('marginTop', 0, 80, 8),
      marginBottom: number('marginBottom', 0, 80, 8),
      paragraphGap: number('paragraphGap', 0, 32, 12),
      paragraphGapOverride:
          json['paragraphGapOverride'] as bool? ??
          number('paragraphGap', 0, 32, 12) != 12,
      catalogueReversed: json['catalogueReversed'] == true,
      indent: json['indent'] == true,
      justify: json['justify'] == true,
      tapPaging: json['tapPaging'] == true,
      tapBothSidesNext: json['tapBothSidesNext'] == true,
      volumePaging: json['volumePaging'] == true,
      brightness: json['brightness'] == null
          ? null
          : number('brightness', 0, 1, 1),
      nightTextBrightness: number('nightTextBrightness', .35, 1, .82),
      letterSpacing: number('letterSpacing', -.5, 3, .1),
      textWeight: ReaderTextWeight.values.byName(
        json['textWeight'] ?? 'regular',
      ),
      statusFontSize: number('statusFontSize', 9, 18, 12),
      headerMarginTop: json['headerMarginTop'] != null
          ? number('headerMarginTop', 0, 48, 0)
          : json['infoMarginTop'] != null
          ? number('infoMarginTop', 0, 48, 0)
          : math.max(0.0, legacyTopOffset),
      headerMarginBottom: number('headerMarginBottom', 0, 48, 0),
      headerMarginLeft: json['headerMarginLeft'] != null
          ? number('headerMarginLeft', 0, 80, 26)
          : json['infoMarginLeft'] != null
          ? number('infoMarginLeft', 0, 80, 26)
          : (legacySideInset > 0
                ? (baseLeft + legacySideInset).clamp(0.0, 80.0)
                : null),
      headerMarginRight: json['headerMarginRight'] != null
          ? number('headerMarginRight', 0, 80, 26)
          : json['infoMarginRight'] != null
          ? number('infoMarginRight', 0, 80, 26)
          : (legacySideInset > 0
                ? (baseRight + legacySideInset).clamp(0.0, 80.0)
                : null),
      footerMarginTop: number('footerMarginTop', 0, 48, 0),
      footerMarginBottom: json['footerMarginBottom'] != null
          ? number('footerMarginBottom', 0, 48, 0)
          : number('infoMarginBottom', 0, 48, 0),
      footerMarginLeft: json['footerMarginLeft'] != null
          ? number('footerMarginLeft', 0, 80, 26)
          : json['infoMarginLeft'] != null
          ? number('infoMarginLeft', 0, 80, 26)
          : (legacySideInset > 0
                ? (baseLeft + legacySideInset).clamp(0.0, 80.0)
                : null),
      footerMarginRight: json['footerMarginRight'] != null
          ? number('footerMarginRight', 0, 80, 26)
          : json['infoMarginRight'] != null
          ? number('infoMarginRight', 0, 80, 26)
          : (legacySideInset > 0
                ? (baseRight + legacySideInset).clamp(0.0, 80.0)
                : null),
      backgroundImage: json['backgroundImage'] as String?,
      backgroundOpacity: number('backgroundOpacity', .05, 1, .18),
      backgroundFit: (json['backgroundFit'] ?? 'cover') == 'contain'
          ? BoxFit.contain
          : BoxFit.cover,
      autoScrollSpeed: number('autoScrollSpeed', 8, 80, 24),
      mode: ReaderMode.values.byName(json['mode'] ?? 'scroll'),
      verticalLatinOrientation: ReaderVerticalLatinOrientation.values.byName(
        json['verticalLatinOrientation'] ?? 'rotated',
      ),
      tapLayout: ReaderTapLayout.values.byName(json['tapLayout'] ?? 'standard'),
      edgeBrightness: json['edgeBrightness'] == true,
      hideSystemStatus: json['hideSystemStatus'] == true,
      showStatusInfo: json['headerVisibility'] == null
          ? legacyShowStatus
          : parsedHeaderVisibility != ReaderBarVisibility.hide,
      headerVisibility: parsedHeaderVisibility,
      footerVisibility: parsedFooterVisibility,
      headerLeft: template('headerLeft', defaultReaderHeaderLeft),
      headerMiddle: template('headerMiddle', defaultReaderHeaderMiddle),
      headerRight: template('headerRight', defaultReaderHeaderRight),
      footerLeft: template('footerLeft', defaultReaderFooterLeft),
      footerMiddle: template('footerMiddle', defaultReaderFooterMiddle),
      footerRight: template('footerRight', defaultReaderFooterRight),
      infoTextColor: colorOrNull('infoTextColor'),
      infoDividerMode: parsedDividerMode,
      infoDividerColor: colorOrNull('infoDividerColor'),
      chapterEntrance: json['chapterEntrance'] == true,
      pageEffect: ReaderPageEffect.values.byName(
        json['pageEffect'] ?? 'staggered',
      ),
      pageSpeed: ReaderPageSpeed.values.byName(json['pageSpeed'] ?? 'normal'),
    );
  }
  static ReaderPreferences fromRecord(Object? record) {
    try {
      return ReaderPreferences.fromJson(jsonDecode(record as String));
    } catch (_) {
      return const ReaderPreferences();
    }
  }

  ReaderPreferences copyWith({
    ReaderPaper? paper,
    List<ReaderCustomPalette>? customPalettes,
    String? customPaletteId,
    bool clearCustomPalette = false,
    double? margin,
    double? marginLeft,
    double? marginRight,
    double? marginTop,
    double? marginBottom,
    double? paragraphGap,
    bool? paragraphGapOverride,
    bool? catalogueReversed,
    bool? indent,
    bool? justify,
    bool? tapPaging,
    bool? tapBothSidesNext,
    bool? volumePaging,
    double? brightness,
    bool systemBrightness = false,
    double? autoScrollSpeed,
    ReaderMode? mode,
    ReaderVerticalLatinOrientation? verticalLatinOrientation,
    ReaderTapLayout? tapLayout,
    bool? edgeBrightness,
    ReaderPageEffect? pageEffect,
    ReaderPageSpeed? pageSpeed,
    bool? hideSystemStatus,
    bool? showStatusInfo,
    ReaderBarVisibility? headerVisibility,
    ReaderBarVisibility? footerVisibility,
    String? headerLeft,
    String? headerMiddle,
    String? headerRight,
    String? footerLeft,
    String? footerMiddle,
    String? footerRight,
    Color? infoTextColor,
    bool clearInfoTextColor = false,
    ReaderInfoDividerMode? infoDividerMode,
    Color? infoDividerColor,
    bool clearInfoDividerColor = false,
    bool? chapterEntrance,
    double? nightTextBrightness,
    double? letterSpacing,
    ReaderTextWeight? textWeight,
    double? statusFontSize,
    double? headerMarginTop,
    double? headerMarginBottom,
    double? headerMarginLeft,
    double? headerMarginRight,
    bool clearHeaderHorizontalMargins = false,
    double? footerMarginTop,
    double? footerMarginBottom,
    double? footerMarginLeft,
    double? footerMarginRight,
    bool clearFooterHorizontalMargins = false,
    String? backgroundImage,
    bool clearBackground = false,
    double? backgroundOpacity,
    BoxFit? backgroundFit,
  }) {
    final nextHeaderVisibility =
        headerVisibility ??
        (showStatusInfo != null
            ? (showStatusInfo
                  ? ReaderBarVisibility.hideWhenStatusShown
                  : ReaderBarVisibility.hide)
            : this.headerVisibility);
    final nextShowStatusInfo =
        showStatusInfo ?? (nextHeaderVisibility != ReaderBarVisibility.hide);
    return ReaderPreferences(
      paper: paper ?? this.paper,
      customPalettes: customPalettes == null
          ? this.customPalettes
          : List.unmodifiable(customPalettes),
      customPaletteId: clearCustomPalette
          ? null
          : customPaletteId ?? this.customPaletteId,
      margin: margin ?? this.margin,
      marginLeft: marginLeft ?? (margin ?? this.marginLeft),
      marginRight: marginRight ?? (margin ?? this.marginRight),
      marginTop: marginTop ?? this.marginTop,
      marginBottom: marginBottom ?? this.marginBottom,
      paragraphGap: paragraphGap ?? this.paragraphGap,
      paragraphGapOverride: paragraphGapOverride ?? this.paragraphGapOverride,
      catalogueReversed: catalogueReversed ?? this.catalogueReversed,
      indent: indent ?? this.indent,
      justify: justify ?? this.justify,
      tapPaging: tapPaging ?? this.tapPaging,
      tapBothSidesNext: tapBothSidesNext ?? this.tapBothSidesNext,
      volumePaging: volumePaging ?? this.volumePaging,
      brightness: systemBrightness ? null : brightness ?? this.brightness,
      autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
      mode: mode ?? this.mode,
      verticalLatinOrientation:
          verticalLatinOrientation ?? this.verticalLatinOrientation,
      tapLayout: tapLayout ?? this.tapLayout,
      edgeBrightness: edgeBrightness ?? this.edgeBrightness,
      pageEffect: pageEffect ?? this.pageEffect,
      pageSpeed: pageSpeed ?? this.pageSpeed,
      hideSystemStatus: hideSystemStatus ?? this.hideSystemStatus,
      showStatusInfo: nextShowStatusInfo,
      headerVisibility: nextHeaderVisibility,
      footerVisibility: footerVisibility ?? this.footerVisibility,
      headerLeft: headerLeft ?? this.headerLeft,
      headerMiddle: headerMiddle ?? this.headerMiddle,
      headerRight: headerRight ?? this.headerRight,
      footerLeft: footerLeft ?? this.footerLeft,
      footerMiddle: footerMiddle ?? this.footerMiddle,
      footerRight: footerRight ?? this.footerRight,
      infoTextColor: clearInfoTextColor
          ? null
          : infoTextColor ?? this.infoTextColor,
      infoDividerMode: infoDividerMode ?? this.infoDividerMode,
      infoDividerColor: clearInfoDividerColor
          ? null
          : infoDividerColor ?? this.infoDividerColor,
      chapterEntrance: chapterEntrance ?? this.chapterEntrance,
      nightTextBrightness: nightTextBrightness ?? this.nightTextBrightness,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      textWeight: textWeight ?? this.textWeight,
      statusFontSize: statusFontSize ?? this.statusFontSize,
      headerMarginTop: headerMarginTop ?? this.headerMarginTop,
      headerMarginBottom: headerMarginBottom ?? this.headerMarginBottom,
      headerMarginLeft:
          headerMarginLeft ??
          (clearHeaderHorizontalMargins ? null : this.headerMarginLeft),
      headerMarginRight:
          headerMarginRight ??
          (clearHeaderHorizontalMargins ? null : this.headerMarginRight),
      footerMarginTop: footerMarginTop ?? this.footerMarginTop,
      footerMarginBottom: footerMarginBottom ?? this.footerMarginBottom,
      footerMarginLeft:
          footerMarginLeft ??
          (clearFooterHorizontalMargins ? null : this.footerMarginLeft),
      footerMarginRight:
          footerMarginRight ??
          (clearFooterHorizontalMargins ? null : this.footerMarginRight),
      backgroundImage: clearBackground
          ? null
          : backgroundImage ?? this.backgroundImage,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      backgroundFit: backgroundFit ?? this.backgroundFit,
    );
  }

  /// A book can keep its typography while interaction and device settings
  /// continue to follow the shared reader. Explicit null margins stay null.
  ReaderPreferences withLayoutOf(ReaderPreferences layout) => ReaderPreferences(
    paper: layout.paper,
    customPalettes: layout.customPalettes,
    customPaletteId: layout.customPaletteId,
    margin: layout.margin,
    marginLeft: layout.marginLeft,
    marginRight: layout.marginRight,
    marginTop: layout.marginTop,
    marginBottom: layout.marginBottom,
    paragraphGap: layout.paragraphGap,
    paragraphGapOverride: layout.paragraphGapOverride,
    catalogueReversed: catalogueReversed,
    indent: layout.indent,
    justify: layout.justify,
    mode: layout.mode,
    verticalLatinOrientation: layout.verticalLatinOrientation,
    nightTextBrightness: layout.nightTextBrightness,
    letterSpacing: layout.letterSpacing,
    textWeight: layout.textWeight,
    backgroundImage: layout.backgroundImage,
    backgroundOpacity: layout.backgroundOpacity,
    backgroundFit: layout.backgroundFit,
    tapPaging: tapPaging,
    tapBothSidesNext: tapBothSidesNext,
    volumePaging: volumePaging,
    brightness: brightness,
    autoScrollSpeed: autoScrollSpeed,
    tapLayout: tapLayout,
    edgeBrightness: edgeBrightness,
    pageEffect: pageEffect,
    pageSpeed: pageSpeed,
    hideSystemStatus: hideSystemStatus,
    showStatusInfo: showStatusInfo,
    headerVisibility: headerVisibility,
    footerVisibility: footerVisibility,
    headerLeft: headerLeft,
    headerMiddle: headerMiddle,
    headerRight: headerRight,
    footerLeft: footerLeft,
    footerMiddle: footerMiddle,
    footerRight: footerRight,
    infoTextColor: infoTextColor,
    infoDividerMode: infoDividerMode,
    infoDividerColor: infoDividerColor,
    chapterEntrance: chapterEntrance,
    statusFontSize: statusFontSize,
    headerMarginTop: headerMarginTop,
    headerMarginBottom: headerMarginBottom,
    headerMarginLeft: headerMarginLeft,
    headerMarginRight: headerMarginRight,
    footerMarginTop: footerMarginTop,
    footerMarginBottom: footerMarginBottom,
    footerMarginLeft: footerMarginLeft,
    footerMarginRight: footerMarginRight,
  );
}
