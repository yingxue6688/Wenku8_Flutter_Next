import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'app_ui.dart';
import 'palette_settings_page.dart' show paletteHex, parsePaletteHex;
import 'reader_preferences.dart';

/// Edits a draft only; dismissing the sheet leaves saved palettes unchanged.
class ReaderPaletteEditor extends StatefulWidget {
  const ReaderPaletteEditor({super.key, required this.initial});

  final ReaderCustomPalette initial;

  @override
  State<ReaderPaletteEditor> createState() => _ReaderPaletteEditorState();
}

class _ReaderPaletteEditorState extends State<ReaderPaletteEditor> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _background = _ColorDraft(widget.initial.background);
  late final _foreground = _ColorDraft(widget.initial.foreground);
  bool _editingBackground = true;

  _ColorDraft get _draft => _editingBackground ? _background : _foreground;
  String get _target => _editingBackground ? '背景色' : '文字色';
  bool get _validName =>
      _name.text.trim().isNotEmpty &&
      _name.text.trim().length <= maximumReaderCustomPaletteNameLength &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(_name.text);
  bool get _canSave => _validName && _background.valid && _foreground.valid;

  void _change(HSVColor value) => setState(() {
    _draft.hsv = value;
    _draft.color = value.toColor();
    _draft.hex.text = paletteHex(_draft.color);
    _draft.valid = true;
  });

  @override
  void dispose() {
    _name.dispose();
    _background.hex.dispose();
    _foreground.hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = _background.color.computeLuminance();
    final second = _foreground.color.computeLuminance();
    final contrast = first > second
        ? (first + .05) / (second + .05)
        : (second + .05) / (first + .05);
    final fieldDecoration = BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: scheme.outlineVariant),
    );
    return SafeArea(
      top: false,
      child: ListView(
        key: const ValueKey('reader-palette-editor-scroll'),
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(
          24,
          18,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        children: [
          const ArchiveSection(title: '自定义配色', code: 'READER / COLOR'),
          const SizedBox(height: 16),
          const AppText('配色名称', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          Semantics(
            label: '配色名称',
            child: CupertinoTextField(
              key: const ValueKey('reader-palette-name'),
              controller: _name,
              maxLength: maximumReaderCustomPaletteNameLength,
              placeholder: '为这组配色命名',
              style: Theme.of(context).textTheme.bodyMedium,
              padding: const EdgeInsets.all(14),
              decoration: fieldDecoration,
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (!_validName)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AppText(
                '请输入 1–40 字的配色名称',
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          Container(
            key: const ValueKey('reader-palette-preview'),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _background.color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: AppText(
              '风吹过书页，故事在此刻继续。\n这是你的阅读配色。',
              style: TextStyle(
                color: _foreground.color,
                fontSize: 16,
                height: 1.8,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final background in [true, false])
                GlassTextButton(
                  key: ValueKey(
                    'reader-palette-target-${background ? 'background' : 'foreground'}',
                  ),
                  selected: _editingBackground == background,
                  onPressed: () => setState(() {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _editingBackground = background;
                  }),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: background
                              ? _background.color
                              : _foreground.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.outline),
                        ),
                      ),
                      const SizedBox(width: 8),
                      AppText(background ? '背景色' : '文字色'),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _ColorBoard(hsv: _draft.hsv, onChanged: _change),
          const SizedBox(height: 12),
          AppText('色相 · ${_draft.hsv.hue.round()}°'),
          _HueBar(
            key: const ValueKey('reader-palette-hue'),
            label: '$_target色相',
            hue: _draft.hsv.hue,
            onChanged: (hue) => _change(_draft.hsv.withHue(hue)),
          ),
          const SizedBox(height: 8),
          AppText('$_target HEX', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          Semantics(
            label: '$_target HEX 色值',
            child: CupertinoTextField(
              key: ValueKey(
                'reader-palette-hex-${_editingBackground ? 'background' : 'foreground'}',
              ),
              controller: _draft.hex,
              maxLength: 7,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: '#F6F5EF',
              style: Theme.of(context).textTheme.bodyMedium,
              padding: const EdgeInsets.all(14),
              decoration: fieldDecoration,
              onChanged: (text) => setState(() {
                final color = parsePaletteHex(text);
                _draft.valid = color != null;
                if (color != null) {
                  _draft.color = color;
                  _draft.hsv = HSVColor.fromColor(color);
                }
              }),
            ),
          ),
          if (!_draft.valid)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AppText(
                '请输入 6 位十六进制色值，例如 #F6F5EF',
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          if (_editingBackground ? !_foreground.valid : !_background.valid)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AppText(
                '${_editingBackground ? '文字色' : '背景色'}的 HEX 色值有误，请切换后修改',
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          if (contrast < 4.5)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AppText(
                '文字与背景较接近，可调整颜色让阅读更清晰。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            alignment: WrapAlignment.end,
            children: [
              GlassTextButton(
                key: const ValueKey('reader-palette-cancel'),
                onPressed: () => Navigator.pop(context),
                child: const AppText('取消'),
              ),
              GlassTextButton(
                key: const ValueKey('reader-palette-save'),
                onPressed: !_canSave
                    ? null
                    : () => Navigator.pop(
                        context,
                        ReaderCustomPalette(
                          id: widget.initial.id,
                          name: _name.text.trim(),
                          background: _background.color,
                          foreground: _foreground.color,
                        ),
                      ),
                child: const AppText('保存并使用'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ColorDraft {
  _ColorDraft(this.color)
    : hsv = HSVColor.fromColor(color),
      hex = TextEditingController(text: paletteHex(color));

  Color color;
  HSVColor hsv;
  final TextEditingController hex;
  bool valid = true;
}

class _ColorBoard extends StatelessWidget {
  const _ColorBoard({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '饱和度与明度颜色板，也可使用下方 HEX 色值输入',
    child: SizedBox(
      height: 160,
      child: LayoutBuilder(
        builder: (context, box) {
          void pick(Offset point) => onChanged(
            hsv
                .withSaturation((point.dx / box.maxWidth).clamp(0.0, 1.0))
                .withValue((1 - point.dy / box.maxHeight).clamp(0.0, 1.0)),
          );

          return GestureDetector(
            key: const ValueKey('reader-palette-color-board'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => pick(details.localPosition),
            onPanStart: (details) => pick(details.localPosition),
            onPanUpdate: (details) => pick(details.localPosition),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white,
                          HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                        ],
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black],
                      ),
                    ),
                  ),
                  Positioned(
                    left: (hsv.saturation * box.maxWidth - 10).clamp(
                      0.0,
                      box.maxWidth - 20,
                    ),
                    top: ((1 - hsv.value) * box.maxHeight - 10).clamp(
                      0.0,
                      box.maxHeight - 20,
                    ),
                    child: IgnorePointer(
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _HueBar extends StatefulWidget {
  const _HueBar({
    super.key,
    required this.label,
    required this.hue,
    required this.onChanged,
  });

  final String label;
  final double hue;
  final ValueChanged<double> onChanged;

  @override
  State<_HueBar> createState() => _HueBarState();
}

class _HueBarState extends State<_HueBar> {
  static const _touchHeight = 48.0;
  static const _barHeight = 20.0;
  static const _thumbSize = 26.0;
  static const _thumbRadius = _thumbSize / 2;
  static const _detentSteps = 20;
  static const _spectrum = <Color>[
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  double _lastHue = 0;
  int _lastTick = 0;

  double _hueAt(double dx, double width) {
    final trackWidth = math.max(1.0, width - _thumbSize);
    return (((dx - _thumbRadius) / trackWidth).clamp(0.0, 1.0) * 360).clamp(
      0.0,
      360.0,
    );
  }

  int _tickFor(double hue) => ((hue / 360) * _detentSteps).round();

  double _steppedHue(double hue, int direction) =>
      (hue + 360 / _detentSteps * direction).clamp(0.0, 360.0);

  void _step(int direction) {
    final current = widget.hue.clamp(0.0, 360.0);
    final next = _steppedHue(current, direction);
    if (next == current) return;
    AppHaptics.play(
      context,
      next == 0 || next == 360 ? HapticCue.boundary : HapticCue.detent,
    );
    widget.onChanged(next);
  }

  void _tap(double dx, double width) {
    final next = _hueAt(dx, width);
    AppHaptics.play(context, HapticCue.selection);
    _lastHue = next;
    _lastTick = _tickFor(next);
    widget.onChanged(next);
  }

  void _drag(double dx, double width) {
    final next = _hueAt(dx, width);
    if (next == _lastHue) return;
    final tick = _tickFor(next);
    if (next == 0 || next == 360) {
      AppHaptics.play(context, HapticCue.boundary);
    } else if (tick != _lastTick) {
      AppHaptics.play(context, HapticCue.detent);
    }
    _lastHue = next;
    _lastTick = tick;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final normalizedHue = widget.hue.clamp(0.0, 360.0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hueColor = HSVColor.fromAHSV(1, normalizedHue, 1, 1).toColor();
    return Semantics(
      label: widget.label,
      slider: true,
      value: '${normalizedHue.round()}°',
      increasedValue: normalizedHue < 360
          ? '${_steppedHue(normalizedHue, 1).round()}°'
          : null,
      decreasedValue: normalizedHue > 0
          ? '${_steppedHue(normalizedHue, -1).round()}°'
          : null,
      onIncrease: normalizedHue < 360 ? () => _step(1) : null,
      onDecrease: normalizedHue > 0 ? () => _step(-1) : null,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(-1),
        },
        child: Focus(
          canRequestFocus: true,
          child: ExcludeSemantics(
            child: SizedBox(
              height: _touchHeight,
              child: LayoutBuilder(
                builder: (context, box) {
                  final width = box.maxWidth;
                  final trackWidth = math.max(0.0, width - _thumbSize);
                  final pad = width > 0
                      ? (_thumbRadius / width).clamp(0.0, 0.45)
                      : 0.0;
                  final thumbLeft = (normalizedHue / 360) * trackWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onTapUp: (details) =>
                        _tap(details.localPosition.dx, width),
                    onHorizontalDragStart: (details) {
                      _lastHue = normalizedHue;
                      _lastTick = _tickFor(normalizedHue);
                      _drag(details.localPosition.dx, width);
                    },
                    onHorizontalDragUpdate: (details) =>
                        _drag(details.localPosition.dx, width),
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: _barHeight,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              _barHeight / 2,
                            ),
                            gradient: LinearGradient(
                              colors: _spectrum,
                              stops: [
                                for (var i = 0; i < _spectrum.length; i++)
                                  pad +
                                      (i / (_spectrum.length - 1)) *
                                          (1 - 2 * pad),
                              ],
                            ),
                            border: Border.all(
                              color: dark
                                  ? Colors.white.withValues(alpha: .18)
                                  : Colors.black.withValues(alpha: .10),
                              width: .75,
                            ),
                          ),
                        ),
                        Positioned(
                          left: thumbLeft,
                          top: (_touchHeight - _thumbSize) / 2,
                          child: IgnorePointer(
                            child: Container(
                              width: _thumbSize,
                              height: _thumbSize,
                              decoration: BoxDecoration(
                                color: hueColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: .30),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1.5),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: .16),
                                    blurRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
