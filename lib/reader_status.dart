import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_ui.dart';
import 'local_platform.dart';
import 'app_window_insets.dart';
import 'reader_preferences.dart';

const readerInfoPlaceholders = <String>[
  '{书名}',
  '{章节}',
  '{时间}',
  '{电量}',
  '{电量图标}',
  '{电量图标数值}',
  '{页码}',
  '{总页数}',
  '{阅读进度}',
  '{章节序号}',
  '{章节总数}',
];

@immutable
class ReaderInfoContent {
  const ReaderInfoContent({
    this.bookTitle = '',
    this.chapterTitle = '',
    this.pageNumber,
    this.totalPages,
    this.progress = '',
    this.chapterIndex,
    this.chapterCount,
  });

  final String bookTitle;
  final String chapterTitle;
  final String? pageNumber;
  final String? totalPages;
  final String progress;
  final int? chapterIndex;
  final int? chapterCount;
}

bool readerInfoUsesLiveStatus(String template) =>
    template.contains('{时间}') || template.contains('{电量');

String sanitizeReaderInfoTemplate(
  String template, {
  required bool hasPageNumbers,
}) {
  if (hasPageNumbers ||
      (!template.contains('{页码}') && !template.contains('{总页数}'))) {
    return template;
  }
  const marker = '\u0000';
  var normalized = template
      .replaceAll(RegExp(r'\{页码\}\s*[/\-–—]\s*\{总页数\}(?:\s*页)?'), marker)
      .replaceAll(
        RegExp(r'(?:第\s*)?\{页码\}(?:\s*页)?|\{总页数\}(?:\s*页)?'),
        marker,
      )
      .replaceAll(RegExp(r'\(\s*\u0000\s*\)|（\s*\u0000\s*）'), marker)
      .replaceAll(
        RegExp(r'\s*[·•|/\-–—]+\s*\u0000\s*[·•|/\-–—]+\s*'),
        ' · ',
      )
      .replaceAll(RegExp(r'(?:\s*[·•|/\-–—]+\s*)?\u0000(?:\s*[·•|/\-–—]+\s*)?'), '');
  normalized = normalized.replaceAll(marker, '').trim();
  return normalized;
}

String readerInformationTitle(String title, int number) =>
    RegExp(r'^第[零〇一二三四五六七八九十百千万两0-9]+[章话回节]').hasMatch(title.trimLeft())
    ? title
    : '第$number话 · $title';

/// Only this small status line updates on a system time/battery broadcast. Reading
/// text, pagination and glass never rebuild to tick a clock.
class ReaderStatusFooter extends StatefulWidget {
  const ReaderStatusFooter({
    super.key,
    this.leading,
    this.compact = false,
    this.timeAtEnd = false,
    this.showBattery = true,
    this.ink,
    this.interactiveLeading = false,
    this.fontSize,
    this.statusBand = false,
  });
  final Widget? leading;
  final bool compact, timeAtEnd, showBattery;
  final Color? ink;
  final bool interactiveLeading;
  final double? fontSize;
  final bool statusBand;
  static const height = 24.0;
  // Reuse the cutout/status band, not another row below it. Time and battery
  // sit at opposite edges, leaving the camera/sensor area in the middle clear.
  static double heightFor(BuildContext context, {double fontSize = 11}) =>
      math.max(
        math.max(
          MediaQuery.viewPaddingOf(context).top,
          AppWindowInsets.viewPaddingOf(context).top,
        ),
        (MediaQuery.textScalerOf(context).scale(fontSize) * 1.4 + 8).clamp(
          height,
          double.infinity,
        ),
      );
  static const events = EventChannel('org.mewx.wenku8/reader_status');
  // Incoming/outgoing sheets share one native subscription and the same data.
  static final _updates = events.receiveBroadcastStream();
  static Map? _lastStatus;
  static EdgeInsets horizontalInsetsFor(
    BuildContext context, {
    double extra = 0,
    double fontSize = 11,
  }) {
    final media = MediaQuery.of(context);
    return readerStatusInsets(
      size: media.size,
      viewPadding: media.viewPadding,
      features: media.displayFeatures,
      bandHeight: heightFor(context, fontSize: fontSize),
      textScale: media.textScaler.scale(fontSize) / 11,
      extra: extra,
    );
  }

  @override
  State<ReaderStatusFooter> createState() => _ReaderStatusFooterState();
}

/// Keep the two small labels out of off-centre holes, not just a centred notch.
/// Extra inset is bounded by available label space on compact/large-text views.
EdgeInsets readerStatusInsets({
  required Size size,
  required EdgeInsets viewPadding,
  required List<DisplayFeature> features,
  required double bandHeight,
  double textScale = 1,
  double extra = 0,
}) {
  final labelWidth = 64 * textScale;
  final baseLeft = viewPadding.left + 26, baseRight = viewPadding.right + 26;
  final available = math.max(
    0.0,
    (size.width - baseLeft - baseRight - labelWidth * 2 - 16) / 2,
  );
  final inset = extra.clamp(0.0, available);
  var left = baseLeft + inset, right = baseRight + inset;
  final band = Rect.fromLTWH(0, 0, size.width, bandHeight);
  for (final feature in features) {
    if (feature.type != DisplayFeatureType.cutout ||
        !feature.bounds.overlaps(band)) {
      continue;
    }
    final hole = feature.bounds;
    if (hole.center.dx < size.width / 2 &&
        hole.left < left + labelWidth &&
        hole.right > left) {
      left = math.max(left, hole.right + 8);
    } else if (hole.center.dx >= size.width / 2 &&
        hole.right > size.width - right - labelWidth &&
        hole.left < size.width - right) {
      right = math.max(right, size.width - hole.left + 8);
    }
  }
  return EdgeInsets.only(left: left, right: right);
}

class _ReaderStatusFooterState extends State<ReaderStatusFooter>
    with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _subscription;
  late DateTime _time = DateTime.now();
  int? _battery;
  bool _charging = false;
  @override
  void initState() {
    super.initState();
    final cached = ReaderStatusFooter._lastStatus;
    if (cached != null) _readStatus(cached);
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    if (!LocalPlatform.readerAppearance || _subscription != null) return;
    _subscription = ReaderStatusFooter._updates.listen((value) {
      if (!mounted || value is! Map) return;
      ReaderStatusFooter._lastStatus = value;
      setState(() => _readStatus(value));
    }, onError: (Object _) {});
  }

  void _readStatus(Map value) {
    final milliseconds = value['time'], battery = value['battery'];
    if (milliseconds is int) {
      _time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    _battery = battery is int && battery >= 0 && battery <= 100
        ? battery
        : null;
    _charging = value['charging'] == true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _listen();
    } else {
      _subscription?.cancel();
      _subscription = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.fontSize ?? (widget.compact ? 13.0 : 11.0);
    final time =
        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';
    return IgnorePointer(
      ignoring: !widget.interactiveLeading,
      child: SizedBox(
        key: const ValueKey('reader-system-footer'),
        height: widget.statusBand
            ? ReaderStatusFooter.heightFor(context, fontSize: size)
            : widget.compact
            ? MediaQuery.textScalerOf(context).scale(size) * 1.4
            : ReaderStatusFooter.heightFor(context, fontSize: size),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: size,
            height: widget.compact ? 1.4 : 1.3,
            color: widget.ink ?? Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                if (widget.statusBand) ...[
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .36,
                      ),
                      child: widget.leading!,
                    ),
                  ),
                  const Spacer(),
                ] else
                  Expanded(child: widget.leading!),
                const SizedBox(width: 12),
              ] else if (widget.timeAtEnd)
                const Spacer(),
              IgnorePointer(
                child: AppText(time, key: const ValueKey('reader-status-time')),
              ),
              if (widget.leading == null && !widget.timeAtEnd) const Spacer(),
              if (widget.showBattery && _charging)
                const IgnorePointer(
                  child: ArchiveIcon(CupertinoIcons.bolt_fill, size: 11),
                ),
              if (widget.showBattery && _battery != null) ...[
                if (widget.compact) const SizedBox(width: 8),
                IgnorePointer(
                  child: ArchiveIcon(
                    _batteryIconFor(_battery, _charging),
                    size: 15,
                  ),
                ),
                const SizedBox(width: 5),
                IgnorePointer(
                  child: AppText(
                    '$_battery%',
                    key: const ValueKey('reader-status-battery'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

IconData _batteryIconFor(int? battery, bool charging) {
  if (charging) return CupertinoIcons.battery_charging;
  if (battery == null) return CupertinoIcons.battery_100;
  if (battery <= 15) return CupertinoIcons.battery_0;
  if (battery <= 50) return CupertinoIcons.battery_25;
  return CupertinoIcons.battery_100;
}

class ReaderInfoBar extends StatefulWidget {
  const ReaderInfoBar({
    super.key,
    required this.left,
    required this.middle,
    required this.right,
    required this.content,
    required this.fontSize,
    required this.color,
    this.dividerColor,
    this.dividerAbove = false,
    this.statusBand = false,
    this.topPadding = 0,
    this.bottomPadding = 0,
    this.height,
    this.slotKeys,
  });

  final String left, middle, right;
  final ReaderInfoContent content;
  final double fontSize;
  final Color color;
  final Color? dividerColor;
  final bool dividerAbove;
  final bool statusBand;
  final double topPadding, bottomPadding;
  final double? height;
  final ({Key? left, Key? middle, Key? right})? slotKeys;

  static const double dividerSpace = 5.0;

  static double barHeightFor(
    BuildContext context, {
    double fontSize = 12,
    bool hasDivider = false,
  }) =>
      (MediaQuery.textScalerOf(context).scale(fontSize) * 1.4 + 8).clamp(
        ReaderStatusFooter.height,
        double.infinity,
      ) +
      (hasDivider ? dividerSpace : 0.0);

  static bool headerSharesStatusBand(
    BuildContext context,
    ReaderPreferences prefs,
  ) {
    if (!prefs.hideSystemStatus) return false;
    if (prefs.headerMiddle.trim().isEmpty) return true;
    final media = MediaQuery.of(context);
    final safeTop = math.max(
      media.viewPadding.top,
      AppWindowInsets.viewPaddingOf(context).top,
    );
    if (safeTop <= 0) return true;
    final topCutouts = media.displayFeatures.where(
      (f) => f.type == DisplayFeatureType.cutout && f.bounds.top < safeTop,
    );
    if (topCutouts.isEmpty) return false;
    final leftLimit = media.size.width * .28;
    final rightLimit = media.size.width * .72;
    return !topCutouts.any(
      (f) => f.bounds.right > leftLimit && f.bounds.left < rightLimit,
    );
  }

  static double headerBandHeightFor(
    BuildContext context,
    ReaderPreferences prefs, {
    required bool dark,
  }) {
    final hasDivider = prefs.effectiveDividerColor(dark) != null;
    final bar = barHeightFor(
      context,
      fontSize: prefs.statusFontSize,
      hasDivider: hasDivider,
    );
    final base = headerSharesStatusBand(context, prefs)
        ? math.max(
            ReaderStatusFooter.heightFor(
                  context,
                  fontSize: prefs.statusFontSize,
                ) +
                (hasDivider ? dividerSpace : 0.0),
            bar,
          )
        : bar;
    return base + prefs.headerMarginBottom;
  }

  static double topExtentFor(
    BuildContext context,
    ReaderPreferences prefs, {
    required bool dark,
  }) {
    final safeTop = math.max(
      MediaQuery.viewPaddingOf(context).top,
      AppWindowInsets.viewPaddingOf(context).top,
    );
    if (!prefs.showsHeader) return safeTop;
    return headerTopFor(context, prefs) +
        headerBandHeightFor(context, prefs, dark: dark);
  }

  static double headerTopFor(
    BuildContext context,
    ReaderPreferences prefs,
  ) {
    final safeTop = math.max(
      MediaQuery.viewPaddingOf(context).top,
      AppWindowInsets.viewPaddingOf(context).top,
    );
    return (headerSharesStatusBand(context, prefs) ? 0.0 : safeTop) +
        prefs.headerMarginTop;
  }

  static double bottomExtentFor(
    BuildContext context,
    ReaderPreferences prefs, {
    required bool dark,
  }) {
    if (!prefs.showsFooter) return 0;
    return barHeightFor(
          context,
          fontSize: prefs.statusFontSize,
          hasDivider: prefs.effectiveDividerColor(dark) != null,
        ) +
        prefs.footerMarginTop +
        prefs.footerMarginBottom;
  }

  static double footerBottomFor(BuildContext context) => math.max(
    MediaQuery.viewPaddingOf(context).bottom,
    AppWindowInsets.viewPaddingOf(context).bottom,
  );

  static EdgeInsets horizontalInsetsFor(
    BuildContext context,
    ReaderPreferences prefs, {
    required bool footer,
    double? viewportWidth,
  }) {
    final media = MediaQuery.of(context);
    final width =
        viewportWidth != null && viewportWidth > 0 ? viewportWidth : media.size.width;
    final safe = media.viewPadding;
    var left =
        safe.left +
        (footer
            ? prefs.effectiveFooterMarginLeft
            : prefs.effectiveHeaderMarginLeft);
    var right =
        safe.right +
        (footer
            ? prefs.effectiveFooterMarginRight
            : prefs.effectiveHeaderMarginRight);
    final maxHorizontal = math.max(0.0, width - 72);
    if (left + right > maxHorizontal && left + right > 0) {
      final scale = maxHorizontal / (left + right);
      left *= scale;
      right *= scale;
    }
    if (!footer && headerSharesStatusBand(context, prefs)) {
      final labelWidth =
          64 * (media.textScaler.scale(prefs.statusFontSize) / 11);
      final band = Rect.fromLTWH(
        0,
        prefs.headerMarginTop,
        width,
        ReaderStatusFooter.heightFor(context, fontSize: prefs.statusFontSize),
      );
      for (final feature in media.displayFeatures) {
        if (feature.type != DisplayFeatureType.cutout ||
            !feature.bounds.overlaps(band)) {
          continue;
        }
        final hole = feature.bounds;
        if (hole.center.dx < width / 2 &&
            hole.left < left + labelWidth &&
            hole.right > left) {
          left = math.max(left, hole.right + 8);
        } else if (hole.center.dx >= width / 2 &&
            hole.right > width - right - labelWidth &&
            hole.left < width - right) {
          right = math.max(right, width - hole.left + 8);
        }
      }
    }
    return EdgeInsets.only(left: left, right: right);
  }

  @override
  State<ReaderInfoBar> createState() => _ReaderInfoBarState();
}

class _ReaderInfoBarState extends State<ReaderInfoBar>
    with WidgetsBindingObserver {
  static final _tokenPattern = RegExp(
    r'\{(书名|章节|时间|电量|电量图标|电量图标数值|页码|总页数|阅读进度|章节序号|章节总数)\}',
  );

  StreamSubscription<dynamic>? _subscription;
  late DateTime _time = DateTime.now();
  int? _battery;
  bool _charging = false;

  bool get _needsLiveStatus =>
      readerInfoUsesLiveStatus(widget.left) ||
      readerInfoUsesLiveStatus(widget.middle) ||
      readerInfoUsesLiveStatus(widget.right);

  @override
  void initState() {
    super.initState();
    final cached = ReaderStatusFooter._lastStatus;
    if (cached != null) _readStatus(cached);
    WidgetsBinding.instance.addObserver(this);
    _syncSubscription();
  }

  @override
  void didUpdateWidget(ReaderInfoBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSubscription();
  }

  void _syncSubscription() {
    if (!_needsLiveStatus || !LocalPlatform.readerAppearance) {
      _subscription?.cancel();
      _subscription = null;
      return;
    }
    if (_subscription != null) return;
    _subscription = ReaderStatusFooter._updates.listen((value) {
      if (!mounted || value is! Map) return;
      ReaderStatusFooter._lastStatus = value;
      setState(() => _readStatus(value));
    }, onError: (Object _) {});
  }

  void _readStatus(Map value) {
    final milliseconds = value['time'], battery = value['battery'];
    if (milliseconds is int) {
      _time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }
    _battery = battery is int && battery >= 0 && battery <= 100
        ? battery
        : null;
    _charging = value['charging'] == true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncSubscription();
    } else {
      _subscription?.cancel();
      _subscription = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  List<InlineSpan> _buildSpans(String rawTemplate, TextStyle style) {
    final hasPages =
        widget.content.pageNumber != null && widget.content.totalPages != null;
    final template = sanitizeReaderInfoTemplate(
      rawTemplate,
      hasPageNumbers: hasPages,
    );
    if (template.isEmpty) return const [];
    final spans = <InlineSpan>[];
    var cursor = 0;
    final time =
        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

    Widget batteryWidget({required bool showText}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_charging) ...[
          Icon(
            CupertinoIcons.bolt_fill,
            size: math.max(9.0, widget.fontSize * .9),
            color: style.color,
          ),
          const SizedBox(width: 2),
        ],
        Icon(
          _batteryIconFor(_battery, _charging),
          size: math.max(12.0, widget.fontSize * 1.25),
          color: style.color,
        ),
        if (showText && _battery != null) ...[
          const SizedBox(width: 4),
          Text('$_battery%', style: style),
        ],
      ],
    );

    for (final match in _tokenPattern.allMatches(template)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: appText(context, template.substring(cursor, match.start)),
          ),
        );
      }
      final key = match.group(1);
      switch (key) {
        case '书名':
          spans.add(TextSpan(text: appText(context, widget.content.bookTitle)));
        case '章节':
          spans.add(
            TextSpan(text: appText(context, widget.content.chapterTitle)),
          );
        case '时间':
          spans.add(TextSpan(text: time));
        case '电量':
          if (_battery != null) spans.add(TextSpan(text: '$_battery%'));
        case '电量图标':
          if (_battery != null || _charging) {
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: batteryWidget(showText: false),
              ),
            );
          }
        case '电量图标数值':
          if (_battery != null || _charging) {
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: batteryWidget(showText: true),
              ),
            );
          }
        case '页码':
          if (widget.content.pageNumber != null) {
            spans.add(TextSpan(text: widget.content.pageNumber));
          }
        case '总页数':
          if (widget.content.totalPages != null) {
            spans.add(TextSpan(text: widget.content.totalPages));
          }
        case '阅读进度':
          spans.add(TextSpan(text: widget.content.progress));
        case '章节序号':
          if (widget.content.chapterIndex != null) {
            spans.add(TextSpan(text: '${widget.content.chapterIndex}'));
          }
        case '章节总数':
          if (widget.content.chapterCount != null) {
            spans.add(TextSpan(text: '${widget.content.chapterCount}'));
          }
      }
      cursor = match.end;
    }
    if (cursor < template.length) {
      spans.add(TextSpan(text: appText(context, template.substring(cursor))));
    }
    return spans;
  }

  Widget? _slot(
    String template,
    TextStyle style,
    TextAlign align, {
    Key? key,
  }) {
    final spans = _buildSpans(template, style);
    if (spans.isEmpty) return null;
    final hasText = spans.any(
      (s) => s is! TextSpan || (s.text?.trim().isNotEmpty ?? false),
    );
    if (!hasText) return null;
    return Text.rich(
      TextSpan(style: style, children: spans),
      key: key,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: widget.fontSize,
        height: 1.4,
        color: widget.color,
      ),
    );
    final left = _slot(
      widget.left,
      style,
      TextAlign.start,
      key: widget.slotKeys?.left,
    );
    final middle = _slot(
      widget.middle,
      style,
      TextAlign.center,
      key: widget.slotKeys?.middle,
    );
    final right = _slot(
      widget.right,
      style,
      TextAlign.end,
      key: widget.slotKeys?.right,
    );
    final height =
        widget.height ??
        ((widget.statusBand
                ? ReaderStatusFooter.heightFor(
                        context,
                        fontSize: widget.fontSize,
                      ) +
                      (widget.dividerColor != null
                          ? ReaderInfoBar.dividerSpace
                          : 0.0)
                : ReaderInfoBar.barHeightFor(
                    context,
                    fontSize: widget.fontSize,
                    hasDivider: widget.dividerColor != null,
                  )) +
            widget.topPadding +
            widget.bottomPadding);
    final divider = widget.dividerColor == null
        ? null
        : Container(height: .6, color: widget.dividerColor);
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.topPadding > 0) SizedBox(height: widget.topPadding),
            if (divider != null && widget.dividerAbove) ...[
              divider,
              const SizedBox(height: 3.4),
            ],
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (middle != null) {
                    return Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: left ?? const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Align(
                            alignment: Alignment.center,
                            child: middle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: right ?? const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    );
                  }
                  if (left == null && right == null) {
                    return const SizedBox.shrink();
                  }
                  if (left != null && right != null) {
                    return Row(
                      children: [
                        Expanded(child: left),
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * .55,
                          ),
                          child: right,
                        ),
                      ],
                    );
                  }
                  if (left != null) {
                    return Align(alignment: Alignment.centerLeft, child: left);
                  }
                  return Align(alignment: Alignment.centerRight, child: right);
                },
              ),
            ),
            if (divider != null && !widget.dividerAbove) ...[
              const SizedBox(height: 3.4),
              divider,
            ],
            if (widget.bottomPadding > 0) SizedBox(height: widget.bottomPadding),
          ],
        ),
      ),
    );
  }
}
