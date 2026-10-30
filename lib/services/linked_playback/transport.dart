import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/linked_playback/clock.dart';
import 'package:PiliPlus/services/linked_playback/protocol.dart';

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

  int lastReceived = LinkClock.nowUs;

  void send(Map<String, Object?> message) {
    if (_closed) return;
    try {
      _socket.write('${LinkProtocol.encode(message)}\n');
    } catch (_) {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _subscription.cancel();
    // 先发出已写入的消息（如停止）再断开
    _socket
        .close()
        .timeout(const Duration(seconds: 2))
        .then((_) {}, onError: (_) {})
        .whenComplete(_socket.destroy);
    _onClosed(this);
  }
}

Future<RawDatagramSocket> _bindDatagram() async =>
    (await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      LinkProtocol.discoveryPort,
      reuseAddress: true,
    ))
      ..broadcastEnabled = true;

void _sendDatagram(
  RawDatagramSocket? socket,
  Map<String, Object?> message,
  InternetAddress address,
) {
  if (socket == null) return;
  try {
    socket.send(
      utf8.encode(LinkProtocol.encode({'app': LinkProtocol.app, ...message})),
      address,
      LinkProtocol.discoveryPort,
    );
  } catch (_) {}
}

LinkMessage? _decodeDatagram(Datagram datagram) {
  try {
    final message = LinkProtocol.decode(utf8.decode(datagram.data));
    if (message != null && message['app'] == LinkProtocol.app) {
      return message;
    }
  } catch (_) {}
  return null;
}

/// 局域网广播地址：受限广播及各 IPv4 网卡按 /24 推算的子网广播
class _BroadcastTargets {
  static const _refreshUs = 10000000;

  List<InternetAddress> _targets = [InternetAddress('255.255.255.255')];
  int _updatedAt = -_refreshUs;

  Future<List<InternetAddress>> resolve() async {
    final now = LinkClock.nowUs;
    if (now - _updatedAt < _refreshUs) {
      return _targets;
    }
    _updatedAt = now;
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
          final broadcast = InternetAddress.fromRawAddress(
            Uint8List.fromList([raw[0], raw[1], raw[2], 255]),
          );
          targets[broadcast.address] = broadcast;
        }
      }
    } catch (_) {}
    return _targets = targets.values.toList();
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
  final _broadcast = _BroadcastTargets();
  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Timer? _beaconTimer;
  bool _disposed = false;

  Future<void> start() async {
    final server = _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    server.listen(_onSocket, onError: (_) {});
    final udp = _udp = await _bindDatagram();
    udp.listen(_onDatagram, onError: (_) {});
    _beaconTimer = Timer.periodic(_beaconInterval, (_) => _beacon());
    _beacon();
  }

  void _onSocket(Socket socket) {
    if (_disposed) {
      socket.destroy();
      return;
    }
    final connection = LinkConnection(
      socket,
      onMessage: onMessage,
      onClosed: (connection) {
        if (connections.remove(connection) && !_disposed) {
          onDisconnected(connection);
        }
      },
    );
    connections.add(connection);
    onConnected(connection);
  }

  Map<String, Object?> get _beaconMessage => {
    'k': LinkDatagram.beacon,
    'port': _server?.port,
  };

  Future<void> _beacon() async {
    final targets = await _broadcast.resolve();
    if (_disposed) return;
    final message = _beaconMessage;
    for (final target in targets) {
      _sendDatagram(_udp, message, target);
    }
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final udp = _udp;
    if (udp == null) return;
    for (
      var datagram = udp.receive();
      datagram != null;
      datagram = udp.receive()
    ) {
      final message = _decodeDatagram(datagram);
      if (message == null) continue;
      switch (message['k']) {
        case LinkDatagram.probe:
          _sendDatagram(udp, _beaconMessage, datagram.address);
        case LinkDatagram.ping:
          final now = LinkClock.nowUs;
          try {
            udp.send(
              utf8.encode(
                LinkProtocol.encode({
                  'app': LinkProtocol.app,
                  'k': LinkDatagram.pong,
                  's': message['s'],
                  't0': message['t0'],
                  't1': now,
                }),
              ),
              datagram.address,
              datagram.port,
            );
          } catch (_) {}
      }
    }
  }

  void broadcast(Map<String, Object?> message) {
    for (final connection in connections.toList()) {
      connection.send(message);
    }
  }

  void dispose() {
    _disposed = true;
    _beaconTimer?.cancel();
    for (final connection in connections.toList()) {
      connection.close();
    }
    connections.clear();
    _udp?.close();
    _udp = null;
    _server?.close();
    _server = null;
  }
}

/// 跟随端：寻找主控并保持一条控制连接，连接期间持续校准时钟
class FollowerTransport {
  FollowerTransport({
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
  });

  static const _probeInterval = Duration(seconds: 2);
  static const _connectTimeout = Duration(seconds: 3);

  /// 连接后先密集采样，之后每秒一次
  static const _burstCount = 10;
  static const _burstInterval = Duration(milliseconds: 100);
  static const _pingInterval = Duration(seconds: 1);

  final void Function() onConnected;
  final void Function(LinkMessage) onMessage;
  final void Function() onDisconnected;

  final clock = ClockSync();
  final _broadcast = _BroadcastTargets();
  RawDatagramSocket? _udp;
  Timer? _probeTimer;
  Timer? _pingTimer;
  LinkConnection? _connection;
  InternetAddress? _leader;
  bool _connecting = false;
  bool _disposed = false;
  int _pingSeq = 0;

  LinkConnection? get connection => _connection;

  bool get isConnected => _connection != null;

  Future<void> start() async {
    final udp = _udp = await _bindDatagram();
    udp.listen(_onDatagram, onError: (_) {});
    _probeTimer = Timer.periodic(_probeInterval, (_) => _probe());
    _probe();
  }

  Future<void> _probe() async {
    if (_connection != null || _connecting) return;
    final targets = await _broadcast.resolve();
    if (_disposed) return;
    for (final target in targets) {
      _sendDatagram(_udp, const {'k': LinkDatagram.probe}, target);
    }
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final udp = _udp;
    if (udp == null) return;
    for (
      var datagram = udp.receive();
      datagram != null;
      datagram = udp.receive()
    ) {
      final message = _decodeDatagram(datagram);
      if (message == null) continue;
      switch (message['k']) {
        case LinkDatagram.beacon:
          if (message['port'] case final int port
              when _connection == null && !_connecting) {
            _connect(datagram.address, port);
          }
        case LinkDatagram.pong:
          final sentAt = message['t0'];
          final remoteAt = message['t1'];
          if (_connection != null &&
              datagram.address.address == _leader?.address &&
              sentAt is int &&
              remoteAt is int) {
            clock.add(
              sentAt: sentAt,
              remoteAt: remoteAt,
              receivedAt: LinkClock.nowUs,
            );
          }
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
      if (_disposed) {
        socket.destroy();
        return;
      }
      _leader = address;
      clock.reset();
      _connection = LinkConnection(
        socket,
        onMessage: (_, message) => onMessage(message),
        onClosed: _onClosed,
      );
      _pingSeq = 0;
      _schedulePing();
      onConnected();
    } catch (_) {
    } finally {
      _connecting = false;
    }
  }

  void _schedulePing() {
    _pingTimer?.cancel();
    _pingTimer = Timer(
      _pingSeq < _burstCount ? _burstInterval : _pingInterval,
      () {
        final leader = _leader;
        if (_connection == null || leader == null) return;
        _sendDatagram(_udp, {
          'k': LinkDatagram.ping,
          's': _pingSeq++,
          't0': LinkClock.nowUs,
        }, leader);
        _schedulePing();
      },
    );
  }

  void _onClosed(LinkConnection connection) {
    if (!identical(connection, _connection)) return;
    _connection = null;
    _leader = null;
    _pingTimer?.cancel();
    clock.reset();
    if (!_disposed) {
      onDisconnected();
      _probe();
    }
  }

  void send(Map<String, Object?> message) => _connection?.send(message);

  void dispose() {
    _disposed = true;
    _probeTimer?.cancel();
    _pingTimer?.cancel();
    _connection?.close();
    _connection = null;
    _udp?.close();
    _udp = null;
  }
}
