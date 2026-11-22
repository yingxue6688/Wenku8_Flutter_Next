import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'reader_chrome.dart';
import 'reader_preferences.dart';
import 'reader_status.dart';

/// Listen to pixels locally, but rebuild only when the displayed percentage
/// changes. Source progress uses only mounted row geometry after layout, never
/// eager paragraph layout, disk writes or article rebuilds on a fling.
class ReaderScrollLocation extends StatefulWidget {
  const ReaderScrollLocation({
    super.key,
    required this.controller,
    required this.title,
    required this.margin,
    required this.ink,
    required this.paper,
    this.sourceFraction,
    this.sourceTitle,
    this.sourceChapterIndex,
    this.bookTitle,
    this.chapterIndex,
    this.chapterCount,
    this.footer = false,
    this.showClock = false,
    this.showBattery = false,
    this.onFractionChanged,
    this.onInfoChanged,
    this.chrome,
    this.reduceMotion = false,
    this.statusFontSize,
    this.statusBand = false,
    this.transparentPaper = false,
    this.visible = true,
    this.preferences,
  });
  final ScrollController controller;
  final String title;
  final EdgeInsets margin;
  final Color ink, paper;
  final double? Function(double viewportOffset)? sourceFraction;
  final String? Function(double viewportOffset)? sourceTitle;
  final int? Function(double viewportOffset)? sourceChapterIndex;
  final String? bookTitle;
  final int? chapterIndex;
  final int? chapterCount;
  final bool footer, showClock, showBattery;
  final ValueChanged<double>? onFractionChanged;
  final void Function(String title, int percent, int? chapterIndex)?
  onInfoChanged;
  final Animation<double>? chrome;
  final bool reduceMotion;
  final double? statusFontSize;
  final bool statusBand;
  final bool transparentPaper;
  final bool visible;
  final ReaderPreferences? preferences;
  static double extentOf(
    BuildContext context, {
    double fontSize = 13,
    bool hasDivider = false,
  }) =>
      math.max(
        24,
        MediaQuery.textScalerOf(context).scale(fontSize) * 1.4 + 6,
      ) +
      (hasDivider ? ReaderInfoBar.dividerSpace : 0.0);

  @override
  State<ReaderScrollLocation> createState() => _ReaderScrollLocationState();
}

class _ReaderScrollLocationState extends State<ReaderScrollLocation> {
  int _percent = 0;
  String? _title;
  int? _chapterIndex;
  bool _updateQueued = false;
  int? _reportedPercent;
  (String, int, int?)? _reportedInfo;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateAfterLayout);
    _updateAfterLayout();
  }

  void _updateAfterLayout() {
    if (_updateQueued) return;
    _updateQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateQueued = false;
      if (mounted) _update();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _update() {
    final controller = widget.controller;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return;
    }
    final maximum = controller.position.maxScrollExtent;
    final source = widget.sourceFraction;
    final fraction = !widget.footer && widget.onFractionChanged == null
        ? null
        : source == null
        ? (maximum > 0 ? controller.offset / maximum : 0.0)
        : controller.offset <= .5
        ? 0.0
        : controller.position.extentAfter <= .5
        ? 1.0
        : source(controller.offset);
    // A layout/restore can temporarily have no mounted source row. Keep the
    // last verified location instead of substituting an unrelated estimate.
    final percent = fraction == null
        ? _percent
        : (fraction * 100).clamp(0, 100).round();
    final title = widget.sourceTitle == null
        ? widget.title
        : widget.sourceTitle!(controller.offset) ?? _title ?? widget.title;
    final chapterIndex = widget.sourceChapterIndex == null
        ? widget.chapterIndex
        : widget.sourceChapterIndex!(controller.offset) ??
              _chapterIndex ??
              widget.chapterIndex;
    if (fraction != null && _reportedPercent != percent) {
      _reportedPercent = percent;
      widget.onFractionChanged?.call(fraction.clamp(0.0, 1.0));
    }
    final nextInfo = (title, percent, chapterIndex);
    if (_reportedInfo != nextInfo) {
      _reportedInfo = nextInfo;
      widget.onInfoChanged?.call(title, percent, chapterIndex);
    }
    if (_percent != percent ||
        _title != title ||
        _chapterIndex != chapterIndex) {
      setState(() {
        _percent = percent;
        _title = title;
        _chapterIndex = chapterIndex;
      });
    }
  }

  @override
  void didUpdateWidget(ReaderScrollLocation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_updateAfterLayout);
      widget.controller.addListener(_updateAfterLayout);
    }
    if (oldWidget.onFractionChanged != widget.onFractionChanged) {
      _reportedPercent = null;
    }
    if (oldWidget.onInfoChanged != widget.onInfoChanged) {
      _reportedInfo = null;
    }
    // Font, margins or viewport changes can update maxScrollExtent without
    // changing pixels, so a scroll listener alone leaves the label stale.
    _updateAfterLayout();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateAfterLayout);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final preferences = widget.preferences;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SelectionContainer.disabled(
      child: Stack(
        children: [
          if (!widget.transparentPaper)
            Positioned.fill(
              child: IgnorePointer(child: ColoredBox(color: widget.paper)),
            ),
          Padding(
            padding: widget.margin,
            child: preferences != null
                ? ReaderInfoBar(
                    key: const ValueKey('reader-scroll-info-footer'),
                    left: preferences.footerLeft,
                    middle: preferences.footerMiddle,
                    right: preferences.footerRight,
                    fontSize: preferences.statusFontSize,
                    color: preferences.effectiveInfoColor(dark),
                    dividerColor: preferences.effectiveDividerColor(dark),
                    dividerAbove: true,
                    topPadding: preferences.footerMarginTop,
                    bottomPadding: preferences.footerMarginBottom,
                    height: ReaderInfoBar.bottomExtentFor(
                      context,
                      preferences,
                      dark: dark,
                    ),
                    content: ReaderInfoContent(
                      bookTitle: widget.bookTitle ?? '',
                      chapterTitle: _title ?? widget.title,
                      progress: '$_percent%',
                      chapterIndex: _chapterIndex ?? widget.chapterIndex,
                      chapterCount: widget.chapterCount,
                    ),
                  )
                : DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize:
                          widget.statusFontSize ??
                          (widget.footer || widget.showClock ? 13 : 11),
                      height: widget.footer || widget.showClock ? 1.4 : 1.3,
                      color: widget.ink.withValues(alpha: .72),
                    ),
                    child: widget.showClock
                        ? ReaderStatusFooter(
                            compact: true,
                            fontSize: widget.statusFontSize,
                            statusBand: widget.statusBand,
                            timeAtEnd: true,
                            showBattery: widget.showBattery,
                            interactiveLeading: true,
                            ink: widget.ink.withValues(alpha: .72),
                            leading: ReaderChapterTitle(
                              text: _title ?? widget.title,
                              key: const ValueKey(
                                'reader-scroll-chapter-title',
                              ),
                              chrome: widget.chrome,
                              showWithChrome: false,
                              reduceMotion: widget.reduceMotion,
                            ),
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: widget.footer && widget.bookTitle != null
                                    ? AppText(
                                        widget.bookTitle!,
                                        key: const ValueKey(
                                          'reader-scroll-book-title',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    : ReaderChapterTitle(
                                        text: _title ?? widget.title,
                                        chrome: widget.chrome,
                                        showWithChrome: false,
                                        reduceMotion: widget.reduceMotion,
                                      ),
                              ),
                              const SizedBox(width: 12),
                              AppText(
                                '$_percent%',
                                key: const ValueKey('reader-scroll-percent'),
                              ),
                            ],
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
