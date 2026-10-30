import 'dart:convert';

typedef LinkMessage = Map<String, dynamic>;

abstract final class LinkProtocol {
  /// 发现与时钟校准共用的 UDP 端口，主控与跟随端都监听此端口
  static const discoveryPort = 41763;

  /// 区分本功能的报文
  static const app = 'PiliPlus.linked';

  static String encode(Map<String, Object?> message) => jsonEncode(message);

  static LinkMessage? decode(String text) {
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) {
        return value;
      }
    } catch (_) {}
    return null;
  }
}

/// UDP 报文类型（字段 `k`）
abstract final class LinkDatagram {
  /// 主控广播自身的控制端口
  static const beacon = 'beacon';

  /// 跟随端寻找主控，主控以 [beacon] 单播回应
  static const probe = 'probe';

  /// 时钟校准请求与回应
  static const ping = 'ping';
  static const pong = 'pong';
}

/// 控制连接上的消息类型（字段 `t`）
///
/// 位置与时刻均为微秒，时刻使用主控的单调时钟
abstract final class LinkMessageType {
  /// 跟随端 → 主控：连接后的第一条消息
  static const hello = 'hello';

  /// 主控 → 跟随端：延迟偏移（毫秒）
  static const config = 'config';

  /// 主控 → 跟随端：本轮播放的内容，跟随端开始加载
  static const open = 'open';

  /// 跟随端 → 主控：本轮内容已加载
  static const loaded = 'loaded';

  /// 主控 → 跟随端：暂停并定位到指定位置
  static const prepare = 'prepare';

  /// 跟随端 → 主控：已定位且缓冲就绪
  static const ready = 'ready';

  /// 主控 → 跟随端：在约定时刻开始播放
  static const start = 'start';

  /// 主控 → 跟随端：暂停在指定位置
  static const pause = 'pause';

  /// 主控 → 跟随端：播放中主控的播放位置采样
  static const position = 'pos';

  /// 主控 → 跟随端：主控不再播放可跟随的内容
  static const stop = 'stop';

  /// 跟随端 → 主控：偏差过大或卡顿，请求重新共同起播
  static const resync = 'resync';

  /// 跟随端 → 主控：实测偏差与往返时间
  static const report = 'report';

  /// 主控 → 跟随端：保持连接
  static const heartbeat = 'hb';
}
