import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';

/// 超过此时间未收到对方任何消息即视为断开；双方每秒至少互发一次
const _silenceTimeoutUs = 8000000;

/// 一条控制连接（TCP），按行收发 JSON
class LinkConnection {
  LinkConnection(
    this._socket, {
    required void Function(LinkConnection, LinkMessage) onMessage,
    required void Function(LinkConnection) onClosed,
  }) : address = _socket.remoteAddress.address,
       _onClosed = onClosed {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    // 写入失败经由 done 报告，由读取端的结束处理关闭
    _socket.done.then((_) {}, onError: (_) {});
    _subscription = utf8.decoder
        .bind(_socket)
        .transform(const LineSplitter())
        .listen(
          (line) {
            lastReceived = LinkClock.nowUs;
            if (LinkProtocol.decode(line) case final message?) {
              onMessage(this, message);
            }
          },
          onDone: close,
          onError: (_) => close(),
          cancelOnError: true,
        );
  }

  final Socket _socket;
  final String address;
  final void Function(LinkConnection) _onClosed;
  late final StreamSubscription<String> _subscription;
  bool _closed = false;

  bool get isClosed => _closed;

  int lastReceived = LinkClock.nowUs;

  void send(Map<String, Object?> message) {
    if (_closed) return;
    try {
      _socket.write('${LinkProtocol.encode(message)}\n');
    } catch (_) {
      close();
    }
  }

  /// 关闭连接；返回的 Future 在已写入的消息发出（或超时）后完成
  Future<void> close() {
    if (_closed) return _closing;
    _closed = true;
    _subscription.cancel();
    // 先发出已写入的消息（如停止）再断开
    _closing = _socket
        .close()
        .timeout(const Duration(seconds: 2))
        .then((_) {}, onError: (_) {})
        .whenComplete(_socket.destroy);
    _onClosed(this);
    return _closing;
  }

  Future<void> _closing = Future.value();
}

/// 发现用的 UDP 套接字，网络变化后可重新绑定
class _Discovery {
  _Discovery(this._onMessage);

  static const _refreshUs = 10000000;

  final void Function(LinkMessage message, InternetAddress from) _onMessage;
  RawDatagramSocket? _socket;
  List<InternetAddress> _targets = [InternetAddress('255.255.255.255')];
  int _targetsAt = -_refreshUs;

  Future<void> bind() async {
    close();
    _targetsAt = -_refreshUs;
    final socket = _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LinkProtocol.discoveryPort,
      reuseAddress: true,
    );
    socket
      ..broadcastEnabled = true
      ..listen(
        (event) {
          if (event == RawSocketEvent.read) _receive(socket);
        },
        onError: (_) {},
      );
  }

  void close() {
    _socket?.close();
    _socket = null;
  }

  void _receive(RawDatagramSocket socket) {
    for (
      var datagram = socket.receive();
      datagram != null;
      datagram = socket.receive()
    ) {
      try {
        final message = LinkProtocol.decode(utf8.decode(datagram.data));
        if (message != null && message['app'] == LinkProtocol.app) {
          _onMessage(message, datagram.address);
        }
      } catch (_) {}
    }
  }

  void send(Map<String, Object?> message, InternetAddress address) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(
        utf8.encode(
          LinkProtocol.encode({'app': LinkProtocol.app, ...message}),
        ),
        address,
        LinkProtocol.discoveryPort,
      );
    } catch (_) {}
  }

  /// 广播到受限广播地址及各 IPv4 网卡按 /24 推算的子网广播地址
  Future<void> broadcast(Map<String, Object?> message) async {
    final now = LinkClock.nowUs;
    if (now - _targetsAt >= _refreshUs) {
      _targetsAt = now;
      final targets = <String, InternetAddress>{
        '255.255.255.255': InternetAddress('255.255.255.255'),
      };
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        for (final item in interfaces) {
          for (final address in item.addresses) {
            if (address.isLoopback) continue;
            final raw = address.rawAddress;
            final target = InternetAddress.fromRawAddress(
              Uint8List.fromList([raw[0], raw[1], raw[2], 255]),
            );
            targets[target.address] = target;
          }
        }
      } catch (_) {}
      _targets = targets.values.toList();
    }
    for (final target in _targets) {
      send(message, target);
    }
  }
}

/// 主控：监听控制连接，广播自身并回应寻找与时钟校准
class LeaderTransport {
  LeaderTransport({
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
  });

  static const _beaconInterval = Duration(seconds: 1);

  final void Function(LinkConnection) onConnected;
  final void Function(LinkConnection, LinkMessage) onMessage;
  final void Function(LinkConnection) onDisconnected;

  final Set<LinkConnection> connections = {};
  late final _discovery = _Discovery(_onDatagram);
  ServerSocket? _server;
  Timer? _timer;
  bool _disposed = false;

  Future<void> start() async {
    ServerSocket server;
    try {
      server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        LinkProtocol.controlPort,
      );
    } on SocketException {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(_onSocket, onError: (_) {});
    await _discovery.bind();
    _timer = Timer.periodic(_beaconInterval, (_) => _onTimer());
    _beacon();
  }

  /// 网络变化后重新绑定发现端口并立即广播
  Future<void> refresh() async {
    if (_disposed) return;
    try {
      await _discovery.bind();
    } catch (_) {}
    _beacon();
  }

  void _onSocket(Socket socket) {
    if (_disposed) {
      socket.destroy();
      return;
    }
    final connection = LinkConnection(
      socket,
      onMessage: _onMessage,
      onClosed: (connection) {
        if (connections.remove(connection) && !_disposed) {
          onDisconnected(connection);
        }
      },
    );
    connections.add(connection);
    onConnected(connection);
  }

  void _onMessage(LinkConnection connection, LinkMessage message) {
    if (message['t'] == LinkMessageType.ping) {
      connection.send({
        't': LinkMessageType.pong,
        't0': message['t0'],
        't1': LinkClock.nowUs,
      });
      return;
    }
    onMessage(connection, message);
  }

  Map<String, Object?> get _beaconMessage => {
    'k': LinkDatagram.beacon,
    'port': _server?.port,
  };

  void _beacon() {
    if (!_disposed) {
      _discovery.broadcast(_beaconMessage);
    }
  }

  void _onTimer() {
    final now = LinkClock.nowUs;
    for (final connection in connections.toList()) {
      if (now - connection.lastReceived > _silenceTimeoutUs) {
        connection.close();
      }
    }
    _beacon();
  }

  void _onDatagram(LinkMessage message, InternetAddress from) {
    if (message['k'] == LinkDatagram.probe) {
      _discovery.send(_beaconMessage, from);
    }
  }

  void broadcast(Map<String, Object?> message) {
    for (final connection in connections.toList()) {
      connection.send(message);
    }
  }

  /// 返回的 Future 在各连接已写入的消息发出后完成
  Future<void> dispose() {
    _disposed = true;
    _timer?.cancel();
    final closing = [
      for (final connection in connections.toList()) connection.close(),
    ];
    connections.clear();
    _discovery.close();
    _server?.close();
    _server = null;
    return Future.wait(closing);
  }
}

/// 跟随端：寻找主控并保持一条控制连接，连接期间持续校准时钟
class FollowerTransport {
  FollowerTransport({
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
    required this.onLeader,
    String? lastLeader,
  }) : _lastLeader = lastLeader;

  static const _probeInterval = Duration(seconds: 2);
  static const _connectTimeout = Duration(seconds: 3);

  /// 连接后先密集采样，之后每秒一次
  static const _burstCount = 10;
  static const _burstInterval = Duration(milliseconds: 100);
  static const _pingInterval = Duration(seconds: 1);

  /// 唤醒后确认连接存活的等待时间
  static const _wakeCheckUs = 3000000;

  final void Function() onConnected;
  final void Function(LinkMessage) onMessage;
  final void Function() onDisconnected;

  /// 连接成功的主控地址（host:port），保存后下次可直接连接
  final void Function(String) onLeader;

  final clock = ClockSync();
  late final _discovery = _Discovery(_onDatagram);
  Timer? _probeTimer;
  Timer? _pingTimer;
  LinkConnection? _connection;
  String? _lastLeader;
  bool _connecting = false;
  bool _disposed = false;
  int _pingSeq = 0;
  int? _wakeAt;

  LinkConnection? get connection => _connection;

  bool get isConnected => _connection != null;

  Future<void> start() async {
    await _discovery.bind();
    _probeTimer = Timer.periodic(_probeInterval, (_) => _check());
    _search();
  }

  /// 网络变化后重新绑定发现端口，并确认连接
  Future<void> refresh() async {
    if (_disposed) return;
    try {
      await _discovery.bind();
    } catch (_) {}
    wake();
  }

  /// 亮屏、回到前台、用户操作时：未连接则立即寻找主控，已连接则确认连接存活
  void wake() {
    if (_disposed) return;
    if (_connection == null) {
      _search();
      return;
    }
    _wakeAt = LinkClock.nowUs;
    _sendPing();
  }

  void _check() {
    final connection = _connection;
    if (connection == null) {
      _search();
      return;
    }
    final now = LinkClock.nowUs;
    final wakeAt = _wakeAt;
    if (now - connection.lastReceived > _silenceTimeoutUs ||
        (wakeAt != null &&
            connection.lastReceived < wakeAt &&
            now - wakeAt > _wakeCheckUs)) {
      connection.close();
    } else if (wakeAt != null && connection.lastReceived >= wakeAt) {
      _wakeAt = null;
    }
  }

  void _search() {
    if (_connection != null || _connecting || _disposed) return;
    _discovery.broadcast(const {'k': LinkDatagram.probe});
    // 广播被过滤时直接连接上次的主控
    if (_lastLeader case final last?) {
      final index = last.lastIndexOf(':');
      if (index > 0) {
        final address = InternetAddress.tryParse(last.substring(0, index));
        final port = int.tryParse(last.substring(index + 1));
        if (address != null && port != null) {
          _connect(address, port);
        }
      }
    }
  }

  void _onDatagram(LinkMessage message, InternetAddress from) {
    if (message['k'] == LinkDatagram.beacon &&
        _connection == null &&
        !_connecting) {
      if (message['port'] case final int port) {
        _connect(from, port);
      }
    }
  }

  Future<void> _connect(InternetAddress address, int port) async {
    _connecting = true;
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: _connectTimeout,
      );
      if (_disposed || _connection != null) {
        socket.destroy();
        return;
      }
      clock.reset();
      _wakeAt = null;
      _connection = LinkConnection(
        socket,
        onMessage: _onMessage,
        onClosed: _onClosed,
      );
      final leader = '${address.address}:$port';
      if (leader != _lastLeader) {
        _lastLeader = leader;
        onLeader(leader);
      }
      _pingSeq = 0;
      _schedulePing();
      onConnected();
    } catch (_) {
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(LinkConnection connection, LinkMessage message) {
    if (message['t'] == LinkMessageType.pong) {
      final sentAt = message['t0'];
      final remoteAt = message['t1'];
      if (sentAt is int && remoteAt is int) {
        clock.add(
          sentAt: sentAt,
          remoteAt: remoteAt,
          receivedAt: LinkClock.nowUs,
        );
      }
      return;
    }
    onMessage(message);
  }

  void _sendPing() {
    _connection?.send({'t': LinkMessageType.ping, 't0': LinkClock.nowUs});
  }

  void _schedulePing() {
    _pingTimer?.cancel();
    _pingTimer = Timer(
      _pingSeq < _burstCount ? _burstInterval : _pingInterval,
      () {
        if (_connection == null) return;
        _pingSeq++;
        _sendPing();
        _schedulePing();
      },
    );
  }

  void _onClosed(LinkConnection connection) {
    if (!identical(connection, _connection)) return;
    _connection = null;
    _wakeAt = null;
    _pingTimer?.cancel();
    clock.reset();
    if (!_disposed) {
      onDisconnected();
      _search();
    }
  }

  void send(Map<String, Object?> message) => _connection?.send(message);

  /// 返回的 Future 在已写入的消息发出后完成
  Future<void> dispose() {
    _disposed = true;
    _probeTimer?.cancel();
    _pingTimer?.cancel();
    final closing = _connection?.close() ?? Future<void>.value();
    _connection = null;
    _discovery.close();
    return closing;
  }
}
