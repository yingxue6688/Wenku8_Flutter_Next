import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'reading_report_range.dart';
import 'reading_statistics_data.dart';

class ReadingReportPage extends StatefulWidget {
  const ReadingReportPage({
    super.key,
    required this.state,
    required this.repository,
    this.now,
    this.initialRange = const ReadingReportRange(),
  });

  final LibraryState state;
  final NovelRepository repository;
  final DateTime? now;
  final ReadingReportRange initialRange;

  @override
  State<ReadingReportPage> createState() => _ReadingReportPageState();
}

class _ReadingReportPageState extends State<ReadingReportPage> {
  late final ReadingStatisticsData _data = ReadingStatisticsData(
    state: widget.state,
    repository: widget.repository,
    now: widget.now ?? DateTime.now(),
    period: 30,
  );

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: '阅读报告',
    code: 'PERSONAL / READING REPORT',
    child: ListView(
      padding: featurePadding(context),
      children: [
        ContentPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppText(
                '近期阅读概览',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              AppText('近 30 天阅读时长：${_data.periodSeconds ~/ 60} 分钟'),
              const SizedBox(height: 6),
              AppText('近 30 天活跃天数：${_data.activeDays} 天'),
            ],
          ),
        ),
      ],
    ),
  );
}
