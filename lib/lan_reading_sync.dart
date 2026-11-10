import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'catalog.dart';
import 'library_state.dart';
import 'local_books.dart';

class LanHandoffReceipt {
  const LanHandoffReceipt({
    required this.book,
    required this.position,
    this.online,
  });

  final Novel book;
  final ReadingPosition position;
  final Object? online;
}

class LanHandoffController extends ChangeNotifier {
  LanHandoffReceipt? _received;
  LanHandoffReceipt? get received => _received;

  Future<({Novel book, ReadingPosition position})> resolveReceipt(
    LanHandoffReceipt receipt,
  ) async => (book: receipt.book, position: receipt.position);

  void dismissReceipt() {
    if (_received == null) return;
    _received = null;
    notifyListeners();
  }
}

class LanReadingSync extends ChangeNotifier {
  LanReadingSync({
    required this.state,
    required this.preferences,
    this.books,
    this.repository,
  });

  final LibraryState state;
  final SharedPreferences preferences;
  final LocalBookStore? books;
  final NovelRepository? repository;
  final LanHandoffController handoff = LanHandoffController();

  Future<void> initialize() async {}

  @override
  void dispose() {
    handoff.dispose();
    super.dispose();
  }
}

class LanSyncScope extends InheritedWidget {
  const LanSyncScope({
    super.key,
    required this.sync,
    required super.child,
  });

  final LanReadingSync? sync;

  static LanReadingSync? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanSyncScope>()?.sync;

  @override
  bool updateShouldNotify(LanSyncScope oldWidget) => sync != oldWidget.sync;
}
