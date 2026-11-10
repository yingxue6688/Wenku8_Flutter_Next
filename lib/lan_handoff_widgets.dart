import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'lan_reading_sync.dart';
import 'library_state.dart';

class LanHandoffMonitor extends StatelessWidget {
  const LanHandoffMonitor({
    super.key,
    required this.handoff,
    required this.onContinue,
    required this.reduceMotion,
    required this.noticeWrapper,
    required this.child,
  });

  final LanHandoffController? handoff;
  final Future<void> Function(LanHandoffReceipt receipt) onContinue;
  final bool reduceMotion;
  final Widget Function(Widget notice) noticeWrapper;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class LanSendBookSheet extends StatelessWidget {
  const LanSendBookSheet({
    super.key,
    required this.sync,
    required this.book,
    required this.position,
    required this.reduceMotion,
  });

  final LanReadingSync sync;
  final Novel book;
  final ReadingPosition position;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppText(
          '???????',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        AppText('?????${book.title}'),
        const SizedBox(height: 16),
        GlassTextButton(
          onPressed: () => Navigator.pop(context),
          child: const AppText('??'),
        ),
      ],
    ),
  );
}
