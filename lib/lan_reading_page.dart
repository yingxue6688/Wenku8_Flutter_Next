import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'feature_pages.dart';
import 'lan_reading_sync.dart';

class LanReadingPage extends StatelessWidget {
  const LanReadingPage({
    super.key,
    required this.sync,
    required this.reduceMotion,
  });

  final LanReadingSync sync;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '??????',
    code: 'READING / LAN HANDOFF',
    child: ListView(
      padding: featurePadding(context),
      children: const [
        ContentPanel(
          child: AppText('????????????????????????'),
        ),
      ],
    ),
  );
}
