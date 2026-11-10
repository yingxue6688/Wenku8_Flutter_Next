import 'package:flutter/material.dart';
import '../app_ui.dart';
import 'enhancement.dart';

class ListeningEnhancementSettings extends StatelessWidget {
  const ListeningEnhancementSettings({
    super.key,
    required this.enhancement,
    required this.onChanged,
  });

  final ListeningEnhancement enhancement;
  final ValueChanged<ListeningEnhancementPreference> onChanged;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: enhancement,
    builder: (context, _) {
      final pref = enhancement.preference;
      return ContentPanel(
        child: Row(
          children: [
            const Expanded(
              child: AppText(
                '????',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            AppControls.toggle(
              context,
              value: pref.enabled,
              onChanged: (enabled) =>
                  onChanged(pref.copyWith(enabled: enabled)),
            ),
          ],
        ),
      );
    },
  );
}
