import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../book_identity.dart';
import '../library_state.dart';
import '../network_status.dart';
import 'lightnovel_account.dart';

export 'lightnovel_account.dart' show LightNovelShelfPlan;

/// Session-bound, two-way cloud bookshelf synchronizer for LightNovel.fun.
/// Local imports (`isLocalBook(id)`), caches, reading progress, and source
/// files are never uploaded or removed here.
class LightNovelShelfSync extends ChangeNotifier with WidgetsBindingObserver {
  LightNovelShelfSync({
    required this.account,
    required this.library,
    required this.preferences,
    this.network,
  });

  final LightNovelAccount account;
  final LibraryState library;
  final SharedPreferences preferences;
  final NetworkStatus? network;

  bool syncing = false;
  String? error;
  int? syncedAt;

  bool _disposed = false;
  bool _applying = false;
  bool _foreground = true;
  bool _again = false;
  Timer? _timer;
  Timer? _poll;
  int? _identity;
  Set<int> _observed = {};
  Set<int>? _cloudObserved;

  Set<int> get _local =>
      library.shelf.where((id) => id > 0 && !isLocalBook(id)).toSet();

  static String preferenceKeyForUid(int uid) => 'lightnovelShelfSync.v1.$uid';

  void start() {
    _observed = _local;
    account.addListener(_accountChanged);
    library.addListener(_localChanged);
    network?.addListener(_networkChanged);
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_foreground) schedule();
    });
    _accountChanged();
  }

  void _accountChanged() {
    final id = account.authenticated ? account.profile?.uid : null;
    if (_identity != id) {
      _identity = id;
      error = null;
      syncedAt = null;
      _cloudObserved = null;
      schedule();
    }
    final cloud = account.cloudBooks?.map((book) => book.bookId).toSet();
    if (cloud != null && !setEquals(cloud, _cloudObserved)) {
      _cloudObserved = cloud;
      if (!syncing && !account.busy) schedule();
    }
  }

  void _localChanged() {
    final now = _local;
    if (setEquals(now, _observed)) return;
    _observed = now;
    if (!_applying) schedule();
  }

  void _networkChanged() {
    if (network?.offline != true) schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) schedule();
  }

  void schedule() {
    if (_disposed) return;
    if (syncing) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 650),
      () => unawaited(synchronize()),
    );
  }

  Future<void> synchronize() async {
    if (_disposed ||
        syncing ||
        !account.authenticated ||
        account.profile == null ||
        !_foreground) {
      return;
    }
    if (network?.offline == true) {
      error = '联网后自动同步';
      notifyListeners();
      return;
    }
    if (account.busy) {
      schedule();
      return;
    }

    _timer?.cancel();
    _timer = null;
    syncing = true;
    error = null;
    notifyListeners();

    final uid = account.profile!.uid;
    final session = account.sessionRevision;
    final local = _local;
    final revisions = library.shelfRevisions;
    final key = preferenceKeyForUid(uid);

    try {
      Set<int>? previous(String field) {
        final raw = preferences.getString(key);
        if (raw == null) return null;
        final map = jsonDecode(raw);
        if (map is! Map || map[field] is! List || map[field].length > 20000) {
          throw const FormatException('云书架同步记录有误');
        }
        return (map[field] as List)
            .whereType<int>()
            .where((id) => id > 0 && !isLocalBook(id))
            .toSet();
      }

      final result = await account.exchangeShelf(
        local: local,
        lastLocal: previous('local'),
        lastCloud: previous('cloud'),
      );
      if (_disposed ||
          session != account.sessionRevision ||
          uid != account.profile?.uid) {
        return;
      }

      _applying = true;
      try {
        await library.applyCloudShelf(
          add: result.localAdded,
          remove: result.localRemoved,
          expectedRevisions: revisions,
        );
      } finally {
        _applying = false;
      }

      if (_disposed || session != account.sessionRevision) return;
      final baseline = {...local, ...result.localAdded}
        ..removeAll(result.localRemoved);
      if (!await preferences.setString(
        key,
        jsonEncode({
          'local': baseline.toList(),
          'cloud': result.target.toList(),
        }),
      )) {
        throw const FormatException('同步记录保存失败');
      }
      syncedAt = DateTime.now().millisecondsSinceEpoch;
      if (!setEquals(baseline, _local)) _again = true;
    } catch (failure) {
      if (!_disposed) {
        error = account.formatError(failure);
      }
    } finally {
      syncing = false;
      if (!_disposed) {
        notifyListeners();
        if (_again) {
          _again = false;
          schedule();
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _poll?.cancel();
    account.removeListener(_accountChanged);
    library.removeListener(_localChanged);
    network?.removeListener(_networkChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
