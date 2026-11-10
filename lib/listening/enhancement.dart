import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class ListeningEnhancementPreference {
  const ListeningEnhancementPreference({
    this.enabled = false,
    this.gainDb = 0.0,
  });

  final bool enabled;
  final double gainDb;

  factory ListeningEnhancementPreference.fromJson(Map<dynamic, dynamic> json) {
    final rawGain = json['gainDb'];
    final gain = rawGain is num ? rawGain.toDouble().clamp(0.0, 12.0) : 0.0;
    return ListeningEnhancementPreference(
      enabled: json['enabled'] == true,
      gainDb: gain,
    );
  }

  ListeningEnhancementPreference copyWith({bool? enabled, double? gainDb}) =>
      ListeningEnhancementPreference(
        enabled: enabled ?? this.enabled,
        gainDb: (gainDb ?? this.gainDb).clamp(0.0, 12.0),
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'gainDb': gainDb,
  };

  @override
  bool operator ==(Object other) =>
      other is ListeningEnhancementPreference &&
      other.enabled == enabled &&
      other.gainDb == gainDb;

  @override
  int get hashCode => Object.hash(enabled, gainDb);
}

class ListeningEnhancement extends ChangeNotifier {
  static const _channel = MethodChannel(
    'org.mewx.wenku8/listening_enhancement',
  );

  ListeningEnhancementPreference _preference =
      const ListeningEnhancementPreference();
  ListeningEnhancementPreference get preference => _preference;

  Future<void> configure(
    ListeningEnhancementPreference value, {
    int? audioSessionId,
  }) async {
    _preference = value;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('configure', {
        ...value.toJson(),
        if (audioSessionId != null) 'audioSessionId': audioSessionId,
      });
    } catch (_) {}
  }

  Future<void> setPreference(ListeningEnhancementPreference value) =>
      configure(value);

  @override
  Future<void> dispose() async {
    super.dispose();
  }
}
