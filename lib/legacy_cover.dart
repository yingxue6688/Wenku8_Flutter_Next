import 'dart:async';
import 'dart:typed_data';

import 'online_media.dart';

typedef CoverUrlResolver = Future<String?> Function(int bookId);

/// Loads online book covers via pure-Dart HTTPS with bounded encoded memory,
/// persistent disk caching by `bookId`, and optional URL refresh on 403/410.
abstract final class LegacyCover {
  static OnlineCoverLoader _loader = OnlineCoverLoader();

  static OnlineCoverLoader get loader => _loader;

  static CoverUrlResolver? get urlResolver => _loader.urlResolver;
  static set urlResolver(CoverUrlResolver? value) {
    _loader.urlResolver = value;
  }

  static void configure({
    OnlineCoverLoader? loader,
    CoverUrlResolver? urlResolver,
  }) {
    if (loader != null) _loader = loader;
    if (urlResolver != null) _loader.urlResolver = urlResolver;
  }

  static Uint8List? peek(int aid, {String? url}) => _loader.peek(aid, url: url);

  static Future<Uint8List> bytes(int aid, {String? url}) =>
      _loader.load(aid, url: url);

  /// Explicit local fixtures never query a remote cover endpoint.
  static void seedLocalBytes(int aid, Uint8List bytes) =>
      _loader.seed(aid, bytes);

  static void clearMemory() => _loader.clearMemory();

  static Future<void> clearCache() => _loader.clearCache();
}

/// Pure-Dart online cover loader using `Novel.coverUrl`, optional `bookId` URL
/// resolver for missing/expired URLs, bounded memory LRU, and disk cache keyed
/// by `bookId`.
class OnlineCoverLoader {
  OnlineCoverLoader({
    OnlineMediaClient? mediaClient,
    OnlineImageDiskCache? diskCache,
    bool enableDiskCache = true,
    this.urlResolver,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxEntries = 256,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _mediaClient = mediaClient ?? OnlineMedia.client,
       _diskCache = enableDiskCache
           ? (diskCache ??
                 OnlineImageDiskCache.forApp(
                   'covers',
                   maxBytes: 64 * 1024 * 1024,
                   maxEntries: 1024,
                 ))
           : null,
       now = now ?? DateTime.now,
       assert(maxBytes > 0 && maxEntries > 0);

  final OnlineMediaClient _mediaClient;
  final OnlineImageDiskCache? _diskCache;
  CoverUrlResolver? urlResolver;
  final int maxBytes, maxEntries;
  final Duration retryDelay;
  final DateTime Function() now;

  final _entries = <int, _CoverEntry>{};
  final _pending = <int, ({String? normalizedUrl, Future<Uint8List> future})>{};
  final _failures =
      <int, ({DateTime retryAt, String? normalizedUrl, Future<Uint8List> future})>{};
  int _encodedBytes = 0;

  int get encodedBytes => _encodedBytes;
  int get cachedEntries => _entries.length;
  int get pendingRequests => _pending.length;
  int get cachedFailures => _failures.length;

  static String _diskKey(int aid) => 'cover:$aid';

  static String? _normalize(String? url) {
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return normalizeOnlineImageKey(trimmed);
  }

  _CoverEntry? _touch(int aid, {String? normalizedUrl}) {
    final entry = _entries[aid];
    if (entry == null) return null;
    if (!entry.seeded &&
        normalizedUrl != null &&
        entry.normalizedUrl != null &&
        entry.normalizedUrl != normalizedUrl) {
      return null;
    }
    _entries.remove(aid);
    _entries[aid] = entry;
    return entry;
  }

  Uint8List? peek(int aid, {String? url}) {
    final normalized = _normalize(url);
    final hit = _touch(aid, normalizedUrl: normalized);
    if (hit != null) return hit.bytes;
    if (url != null && url.trim().isNotEmpty) {
      return _mediaClient.peek(url);
    }
    return null;
  }

  void seed(int aid, Uint8List bytes) {
    if (aid <= 0 || bytes.isEmpty) throw ArgumentError('Invalid local cover');
    final local = Uint8List.fromList(bytes).asUnmodifiableView();
    // A delayed older network response must not overwrite an explicit seed.
    _pending.remove(aid);
    _failures.remove(aid);
    _store(aid, _CoverEntry(local, Future.value(local), seeded: true));
  }

  void _store(int aid, _CoverEntry entry) {
    final previous = _entries.remove(aid);
    if (previous != null) _encodedBytes -= previous.bytes.length;
    if (entry.bytes.length > maxBytes) return;
    _entries[aid] = entry;
    _encodedBytes += entry.bytes.length;
    while (_encodedBytes > maxBytes || _entries.length > maxEntries) {
      final removed = _entries.remove(_entries.keys.first)!;
      _encodedBytes -= removed.bytes.length;
    }
  }

  Future<Uint8List> load(int aid, {String? url}) {
    if (aid <= 0) return Future.error(ArgumentError('Invalid cover ID'));
    final trimmedUrl = url?.trim();
    final initialUrl = trimmedUrl != null && trimmedUrl.isNotEmpty
        ? trimmedUrl
        : null;
    final normalizedUrl = initialUrl == null
        ? null
        : normalizeOnlineImageKey(initialUrl);

    final entry = _touch(aid, normalizedUrl: normalizedUrl);
    if (entry != null) return entry.future;

    final failure = _failures[aid];
    if (failure != null &&
        now().isBefore(failure.retryAt) &&
        failure.normalizedUrl == normalizedUrl) {
      return failure.future;
    }
    _failures.remove(aid);

    final pending = _pending[aid];
    if (pending != null &&
        (normalizedUrl == null || pending.normalizedUrl == normalizedUrl)) {
      return pending.future;
    }

    final completer = Completer<Uint8List>();
    final future = completer.future;
    final pendingRecord = (normalizedUrl: normalizedUrl, future: future);
    _pending[aid] = pendingRecord;

    unawaited(() async {
      try {
        Uint8List? image;
        var storedNormalized = normalizedUrl;

        // Check persistent disk cache by bookId first so cached covers survive
        // restarts and expired signature URLs without extra network traffic.
        final diskBytes = await _diskCache?.read(_diskKey(aid));
        if (diskBytes != null && diskBytes.isNotEmpty) {
          image = diskBytes;
        } else {
          final resolver = urlResolver;
          var resolvedFromCallback = false;
          var effectiveUrl = initialUrl;
          if (effectiveUrl == null && resolver != null) {
            effectiveUrl = (await resolver(aid))?.trim();
            resolvedFromCallback = true;
          }
          if (effectiveUrl == null || effectiveUrl.isEmpty) {
            throw const FormatException('封面地址为空');
          }

          String? refreshedUrl;
          image = await _mediaClient.loadImage(
            effectiveUrl,
            cacheForViewing: false,
            refreshUrl: !resolvedFromCallback && resolver != null
                ? (_) async {
                    refreshedUrl = (await resolver(aid))?.trim();
                    return refreshedUrl;
                  }
                : null,
          );
          if (image.isEmpty) throw const FormatException('封面为空');
          final finalUrl =
              refreshedUrl != null && refreshedUrl!.isNotEmpty
              ? refreshedUrl!
              : effectiveUrl;
          storedNormalized = normalizeOnlineImageKey(finalUrl);
          await _diskCache?.write(_diskKey(aid), image);
        }

        final bytes = image.asUnmodifiableView();
        if (identical(_pending[aid]?.future, future)) {
          _store(
            aid,
            _CoverEntry(bytes, future, normalizedUrl: storedNormalized),
          );
        }
        completer.complete(bytes);
      } catch (error, stack) {
        if (identical(_pending[aid]?.future, future)) {
          _failures[aid] = (
            retryAt: now().add(retryDelay),
            normalizedUrl: normalizedUrl,
            future: future,
          );
          while (_failures.length > maxEntries) {
            _failures.remove(_failures.keys.first);
          }
        }
        completer.completeError(error, stack);
      } finally {
        if (identical(_pending[aid]?.future, future)) _pending.remove(aid);
      }
    }());
    return future;
  }

  Future<void> evict(int aid, {bool includeDisk = false}) async {
    final removed = _entries.remove(aid);
    if (removed != null) _encodedBytes -= removed.bytes.length;
    _pending.remove(aid);
    _failures.remove(aid);
    if (includeDisk) {
      await _diskCache?.remove(_diskKey(aid));
    }
  }

  void clearMemory() {
    _entries.clear();
    _pending.clear();
    _failures.clear();
    _encodedBytes = 0;
  }

  Future<void> clearCache() async {
    clearMemory();
    await _diskCache?.clear();
  }
}

/// Bounded in-memory cover cache keyed by book ID (kept for backwards
/// compatibility with callers/tests providing a custom byte loader).
class LegacyCoverCache {
  LegacyCoverCache({
    required this.request,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxEntries = 256,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       assert(maxBytes > 0 && maxEntries > 0);

  final Future<Uint8List?> Function(int) request;
  final int maxBytes, maxEntries;
  final Duration retryDelay;
  final DateTime Function() now;
  final _entries = <int, _CoverEntry>{};
  final _pending = <int, Future<Uint8List>>{};
  final _failures = <int, (DateTime, Future<Uint8List>)>{};
  int _encodedBytes = 0;

  int get encodedBytes => _encodedBytes;
  int get cachedEntries => _entries.length;
  int get pendingRequests => _pending.length;
  int get cachedFailures => _failures.length;

  _CoverEntry? _touch(int aid) {
    final entry = _entries.remove(aid);
    if (entry != null) _entries[aid] = entry;
    return entry;
  }

  Uint8List? peek(int aid, {String? url}) => _touch(aid)?.bytes;

  void seed(int aid, Uint8List bytes) {
    if (aid <= 0 || bytes.isEmpty) throw ArgumentError('Invalid local cover');
    final local = Uint8List.fromList(bytes).asUnmodifiableView();
    // A delayed older network response must not overwrite an explicit seed.
    _pending.remove(aid);
    _failures.remove(aid);
    _store(aid, _CoverEntry(local, Future.value(local), seeded: true));
  }

  void _store(int aid, _CoverEntry entry) {
    final previous = _entries.remove(aid);
    if (previous != null) _encodedBytes -= previous.bytes.length;
    if (entry.bytes.length > maxBytes) return;
    _entries[aid] = entry;
    _encodedBytes += entry.bytes.length;
    while (_encodedBytes > maxBytes || _entries.length > maxEntries) {
      final removed = _entries.remove(_entries.keys.first)!;
      _encodedBytes -= removed.bytes.length;
    }
  }

  Future<Uint8List> load(int aid, {String? url}) {
    if (aid <= 0) return Future.error(ArgumentError('Invalid cover ID'));
    final entry = _touch(aid);
    if (entry != null) return entry.future;
    final failure = _failures[aid];
    if (failure != null && now().isBefore(failure.$1)) return failure.$2;
    _failures.remove(aid);
    final pending = _pending[aid];
    if (pending != null) return pending;
    final completer = Completer<Uint8List>();
    final future = completer.future;
    _pending[aid] = future;
    unawaited(() async {
      try {
        final image = await request(aid);
        if (image == null || image.isEmpty) throw const FormatException('封面为空');
        final bytes = image.asUnmodifiableView();
        if (identical(_pending[aid], future)) {
          _store(aid, _CoverEntry(bytes, future));
        }
        completer.complete(bytes);
      } catch (error, stack) {
        if (identical(_pending[aid], future)) {
          _failures[aid] = (now().add(retryDelay), future);
          // Failed IDs must not grow forever while browsing offline either.
          while (_failures.length > maxEntries) {
            _failures.remove(_failures.keys.first);
          }
        }
        completer.completeError(error, stack);
      } finally {
        if (identical(_pending[aid], future)) _pending.remove(aid);
      }
    }());
    return future;
  }
}

class _CoverEntry {
  const _CoverEntry(
    this.bytes,
    this.future, {
    this.normalizedUrl,
    this.seeded = false,
  });

  final Uint8List bytes;
  final Future<Uint8List> future;
  final String? normalizedUrl;
  final bool seeded;
}
