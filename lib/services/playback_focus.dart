import 'package:flutter/foundation.dart' show VoidCallback;

final playbackFocus = PlaybackFocus._();

/// 视频播放器开始播放时，通知独立的播放器（听音频页）让出播放与系统媒体控制
class PlaybackFocus {
  PlaybackFocus._();

  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void takenByVideo() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}
