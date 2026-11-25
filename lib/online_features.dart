import 'package:flutter/widgets.dart';

import 'lightnovel/lightnovel_account.dart';
import 'lightnovel/lightnovel_repository.dart';
import 'lightnovel/lightnovel_shelf_sync.dart';
import 'publication_catalog.dart';

class OnlineFeatures {
  const OnlineFeatures({
    required this.account,
    required this.publications,
    required this.repository,
    this.shelfSync,
  });

  final LightNovelAccount account;
  final PublicationCatalog publications;
  final LightNovelRepository repository;
  final LightNovelShelfSync? shelfSync;
}

/// Capabilities are injected once, not subscribed at the application root.
class OnlineFeaturesScope extends InheritedWidget {
  const OnlineFeaturesScope({
    super.key,
    required this.features,
    required super.child,
  });

  final OnlineFeatures? features;

  static OnlineFeatures? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<OnlineFeaturesScope>()
      ?.features;

  @override
  bool updateShouldNotify(OnlineFeaturesScope oldWidget) =>
      features != oldWidget.features;
}
