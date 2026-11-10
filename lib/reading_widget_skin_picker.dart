import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'reading_widget_reference.dart';
import 'reading_widget_skin.dart';
import 'reading_widget_snapshot.dart';

class ReadingWidgetSkinPicker extends StatelessWidget {
  const ReadingWidgetSkinPicker({
    super.key,
    required this.previewBuilder,
    required this.value,
    required this.size,
    required this.snapshot,
    required this.onChanged,
  });

  final Widget Function(ReadingWidgetSkin skin) previewBuilder;
  final ReadingWidgetSkin value;
  final ReadingDesktopSize size;
  final ReadingWidgetSnapshot snapshot;
  final ValueChanged<ReadingWidgetSkin>? onChanged;

  @override
  Widget build(BuildContext context) {
    final skins = ReadingWidgetSkin.values
        .where((s) => s != ReadingWidgetSkin.original)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: FittedBox(child: previewBuilder(value))),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final skin in skins)
              GlassTextButton(
                key: ValueKey('reading-widget-skin-${skin.name}'),
                compact: true,
                selected: skin == value,
                onPressed: onChanged == null ? null : () => onChanged!(skin),
                child: AppText(skin.label),
              ),
          ],
        ),
      ],
    );
  }
}
