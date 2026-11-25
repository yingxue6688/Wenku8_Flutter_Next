import 'dart:convert';
import 'package:flutter/services.dart';

/// Method channel backed by Android's `OnlineSessionPlugin` AES-256-GCM vault.
const String onlineSessionChannelName = 'org.mewx.wenku8/online_session';

/// Maximum UTF-8 byte length allowed for an encrypted online session payload.
const int onlineSessionMaxBytes = 32 * 1024;

/// Device-bound encrypted storage for LightNovel online authentication state.
///
/// Payloads are opaque UTF-8 JSON strings up to [onlineSessionMaxBytes] bytes
/// and must never be persisted to plain-text SharedPreferences or backups.
abstract interface class OnlineSessionStore {
  /// Reads the stored session payload, or `null` when absent or discarded.
  Future<String?> read();

  /// Encrypts and persists [payload] (non-blank UTF-8, up to 32 KiB).
  Future<void> write(String payload);

  /// Removes any stored session payload.
  Future<void> clear();
}

/// Convenience JSON object helpers on top of [OnlineSessionStore].
extension OnlineSessionStoreJson on OnlineSessionStore {
  /// Reads and decodes the stored session payload as a JSON object.
  ///
  /// Fails closed: if the stored payload is malformed JSON or not a JSON
  /// object, clears the corrupted record and returns `null`.
  Future<Map<String, dynamic>?> readJson() async {
    final raw = await read();
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // Fall through to fail-closed cleanup.
    }
    try {
      await clear();
    } on PlatformException {
      // Best-effort cleanup when failing closed.
    }
    return null;
  }

  /// Serializes [data] as UTF-8 JSON and persists it in the session store.
  Future<void> writeJson(Map<String, dynamic> data) => write(jsonEncode(data));
}

/// Platform-backed [OnlineSessionStore] using `org.mewx.wenku8/online_session`.
///
/// On platforms or test environments where the native plugin is absent,
/// [MissingPluginException] transparently degrades to an in-memory fallback
/// store rather than crashing or writing secrets to plain-text preferences.
class PlatformOnlineSessionStore implements OnlineSessionStore {
  PlatformOnlineSessionStore({
    MethodChannel channel = defaultChannel,
    OnlineSessionStore? fallback,
  }) : _channel = channel,
       _fallback = fallback ?? MemoryOnlineSessionStore();

  static const MethodChannel defaultChannel = MethodChannel(
    onlineSessionChannelName,
  );

  final MethodChannel _channel;
  final OnlineSessionStore _fallback;
  bool _usingFallback = false;

  /// Whether this store has degraded to its in-memory fallback because the
  /// native platform plugin was not registered.
  bool get isUsingFallback => _usingFallback;

  @override
  Future<String?> read() async {
    if (_usingFallback) {
      return _fallback.read();
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('read');
      if (raw == null) return null;
      if (raw is! String || !_isValidPayload(raw)) {
        await _clearChannelBestEffort();
        return null;
      }
      return raw;
    } on MissingPluginException {
      _usingFallback = true;
      return _fallback.read();
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> write(String payload) async {
    _validatePayload(payload);
    if (_usingFallback) {
      await _fallback.write(payload);
      return;
    }
    try {
      await _channel.invokeMethod<void>('write', <String, Object?>{
        'payload': payload,
      });
    } on MissingPluginException {
      _usingFallback = true;
      await _fallback.write(payload);
    }
  }

  @override
  Future<void> clear() async {
    if (_usingFallback) {
      await _fallback.clear();
      return;
    }
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      _usingFallback = true;
      await _fallback.clear();
    }
  }

  Future<void> _clearChannelBestEffort() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      _usingFallback = true;
      await _fallback.clear();
    } on PlatformException {
      // Best-effort cleanup when discarding a corrupt response.
    }
  }
}

/// In-memory [OnlineSessionStore] for unit tests and non-Android fallback.
class MemoryOnlineSessionStore implements OnlineSessionStore {
  MemoryOnlineSessionStore([String? initialPayload])
    : _payload = initialPayload;

  String? _payload;

  @override
  Future<String?> read() async {
    final current = _payload;
    if (current == null) return null;
    if (!_isValidPayload(current)) {
      _payload = null;
      return null;
    }
    return current;
  }

  @override
  Future<void> write(String payload) async {
    _validatePayload(payload);
    _payload = payload;
  }

  @override
  Future<void> clear() async {
    _payload = null;
  }

  @override
  String toString() =>
      'MemoryOnlineSessionStore(hasSession: ${_payload != null})';
}

bool _isValidPayload(String payload) {
  if (payload.trim().isEmpty) return false;
  return utf8.encode(payload).length <= onlineSessionMaxBytes;
}

void _validatePayload(String payload) {
  if (payload.trim().isEmpty) {
    throw ArgumentError('Session payload must not be empty');
  }
  if (utf8.encode(payload).length > onlineSessionMaxBytes) {
    throw ArgumentError(
      'Session payload exceeds $onlineSessionMaxBytes UTF-8 bytes',
    );
  }
}
