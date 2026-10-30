import 'dart:math' as math;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/linked_playback/offset_dial.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const _textStyle = TextStyle(color: Colors.white, fontSize: 12);
const _dimTextStyle = TextStyle(color: Colors.white70, fontSize: 11);

/// 播放器底栏中的联动控件，从右到左为同步开关、延迟偏移拨轮、跟随端音量；
/// 宽度不足时依次把音量、偏移收进按钮弹出，最窄时整体收为一个按钮
class LinkedBarControls extends StatelessWidget {
  const LinkedBarControls({
    super.key,
    required this.controller,
    required this.onInteraction,
  });

  /// 收起为一个按钮时的宽度，底栏至少为此预留
  static const double minWidth = _buttonWidth;

  static const double _height = 34;
  static const double _gap = 8;
  static const double _buttonWidth = 40;
  static const double _peerWidth = 64;

  /// 本播放器：只在其内容是联动的内容时显示偏移与音量
  final PlPlayerController controller;

  /// 操作期间调用，保持播放器控件显示
  final VoidCallback onInteraction;

  /// 拖动拨轮期间不自动隐藏播放器控件
  void _onDragging(bool dragging) {
    if (dragging) {
      controller.holdControls();
    } else {
      controller.releaseControls();
    }
  }

  /// 是否显示偏移与音量、可调音量的跟随端数量；在 Obx 中调用
  static ({bool adjust, int volumePeers}) _state(
    PlPlayerController controller,
  ) {
    final current = linkedPlayback.current.value;
    // 登记内容先于播放器更新分P，加载完成后再按分P核对
    controller.dataStatus.value;
    final cid = controller.cid;
    final adjust =
        linkedPlayback.syncOn.value &&
        current?.kind == LinkedKind.video &&
        current?.cid == cid;
    return (
      adjust: adjust,
      volumePeers: adjust ? _LinkedVolumeControl.peerCount : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final widths = _Widths.of(context);
    return Obx(() {
      final (:adjust, :volumePeers) = _state(controller);
      final volume = volumePeers > 0;
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final volumeWidth =
              widths.volume + (volumePeers > 1 ? _peerWidth + _gap : 0);
          final List<Widget> children;
          if (!adjust) {
            children = [
              if (width >= widths.sync)
                _LinkedSyncSwitch(widths: widths)
              else
                _panelButton(widths, sync: true, offset: false),
            ];
          } else if (width >=
              widths.sync +
                  _gap +
                  widths.offset +
                  (volume ? _gap + volumeWidth : 0)) {
            children = [
              if (volume)
                _LinkedVolumeControl(
                  widths: widths,
                  onInteraction: onInteraction,
                  onDragging: _onDragging,
                ),
              _LinkedOffsetControl(
                widths: widths,
                onInteraction: onInteraction,
                onDragging: _onDragging,
              ),
              _LinkedSyncSwitch(widths: widths),
            ];
          } else if (volume &&
              width >=
                  widths.sync + _gap + widths.offset + _gap + _buttonWidth) {
            children = [
              _panelButton(widths, sync: false, offset: false),
              _LinkedOffsetControl(
                widths: widths,
                onInteraction: onInteraction,
                onDragging: _onDragging,
              ),
              _LinkedSyncSwitch(widths: widths),
            ];
          } else if (width >= widths.sync + _gap + _buttonWidth) {
            children = [
              _panelButton(widths, sync: false, offset: true),
              _LinkedSyncSwitch(widths: widths),
            ];
          } else {
            children = [_panelButton(widths, sync: true, offset: true)];
          }
          return SizedBox(
            height: _height,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: _gap,
              children: children,
            ),
          );
        },
      );
    });
  }

  /// 收起的控件：点击后在弹出层中显示；[sync] 含同步开关，[offset] 含偏移，
  /// 音量总在其中，内容随联动状态更新
  Widget _panelButton(
    _Widths widths, {
    required bool sync,
    required bool offset,
  }) {
    return PopupMenuButton<void>(
      tooltip: sync ? '联动播放' : (offset ? '联动调节' : '跟随端音量'),
      requestFocus: false,
      color: Colors.black.withValues(alpha: 0.8),
      constraints: BoxConstraints(
        minWidth: 260,
        maxWidth: math.max(320.0, widths.panel + 2 * _PanelEntry._padding),
      ),
      onOpened: onInteraction,
      itemBuilder: (context) => [
        _PanelEntry(
          controller: controller,
          sync: sync,
          offset: offset,
          onInteraction: onInteraction,
          onDragging: _onDragging,
        ),
      ],
      child: SizedBox(
        width: _buttonWidth,
        height: _height,
        child: Center(
          child: sync
              ? Obx(() {
                  final on = linkedPlayback.syncOn.value;
                  return Icon(
                    on ? Icons.link_rounded : Icons.link_off_rounded,
                    size: 22,
                    color: on && linkedPlayback.isConnected
                        ? Colors.white
                        : Colors.white54,
                  );
                })
              : Icon(
                  offset ? Icons.tune_rounded : Icons.volume_up_outlined,
                  size: 20,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }
}

/// 控件宽度：文本部分按当前字体、缩放与粗体设置实际排版量出
class _Widths {
  const _Widths({
    required this.sync,
    required this.offsetValue,
    required this.offsetZero,
    required this.toggle,
    required this.volumeValue,
  });

  factory _Widths.of(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    var base = DefaultTextStyle.of(context).style;
    if (MediaQuery.boldTextOf(context)) {
      base = base.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width.ceilToDouble();
      painter.dispose();
      return width;
    }

    var toggle = 2.0;
    for (final mode in LinkedVolumeMode.values) {
      toggle += measure(mode.label, _textStyle) + 2 * _modePadding;
    }
    return _Widths(
      sync:
          _switchWidth +
          _spacing +
          math.max(measure('同步', _textStyle), measure('未连接', _textStyle)),
      offsetValue: math.max(60.0, measure('-88.8 ms', _textStyle)),
      offsetZero: math.max(36.0, measure('归零', _dimTextStyle) + 12),
      toggle: toggle,
      volumeValue: math.max(
        40.0,
        math.max(measure('-100', _textStyle), measure('100%', _textStyle)),
      ),
    );
  }

  static const double _switchWidth = 38;
  static const double _spacing = 4;
  static const double _modePadding = 7;
  static const double _offsetDial = 104;
  static const double _volumeDial = 84;
  static const double _volumeIcon = 18;

  final double sync;

  /// 偏移值文本与归零按钮
  final double offsetValue;
  final double offsetZero;

  /// 音量模式切换
  final double toggle;

  /// 音量值文本
  final double volumeValue;

  double get offset => offsetValue + _spacing + _offsetDial + offsetZero;

  double get volume =>
      _volumeIcon +
      _spacing +
      toggle +
      _spacing +
      volumeValue +
      _spacing +
      _volumeDial;

  /// 弹出层内容
  double get panel => math.max(sync, math.max(offset, volume));
}

/// 弹出层中不可选的整块内容：打开期间保持播放器控件显示；内容随联动状态
/// 更新，没有可显示的内容时关闭
class _PanelEntry extends PopupMenuEntry<void> {
  const _PanelEntry({
    required this.controller,
    required this.sync,
    required this.offset,
    required this.onInteraction,
    required this.onDragging,
  });

  static const double _padding = 12;

  final PlPlayerController controller;
  final bool sync;
  final bool offset;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onDragging;

  @override
  double get height => LinkedBarControls._height;

  @override
  bool represents(void value) => false;

  @override
  State<_PanelEntry> createState() => _PanelEntryState();
}

class _PanelEntryState extends State<_PanelEntry> {
  late final PlPlayerController _controller;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller..holdControls();
  }

  @override
  void dispose() {
    _controller.releaseControls();
    super.dispose();
  }

  void _close(ModalRoute<Object?>? route) {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route == null || !route.isActive) return;
      if (route.isCurrent) {
        route.navigator?.pop();
      } else {
        route.navigator?.removeRoute(route);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final widths = _Widths.of(context);
    final route = ModalRoute.of(context);
    return Obx(() {
      final (:adjust, :volumePeers) = LinkedBarControls._state(
        widget.controller,
      );
      final children = [
        if (widget.sync) _LinkedSyncSwitch(widths: widths),
        if (widget.offset && adjust)
          _LinkedOffsetControl(
            widths: widths,
            onInteraction: widget.onInteraction,
            onDragging: widget.onDragging,
          ),
        if (volumePeers > 0)
          _LinkedVolumeControl(
            widths: widths,
            onInteraction: widget.onInteraction,
            onDragging: widget.onDragging,
            stacked: true,
          ),
      ];
      if (children.isEmpty) {
        _close(route);
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _PanelEntry._padding,
          vertical: 4,
        ),
        // 屏幕窄于内容时整体缩小
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 6,
            children: children,
          ),
        ),
      );
    });
  }
}

/// 同步开关：两端共用；已开启但未连接时点击只重连，不改动开关
class _LinkedSyncSwitch extends StatelessWidget {
  const _LinkedSyncSwitch({required this.widths});

  final _Widths widths;

  static void _onTap() {
    if (linkedPlayback.syncOn.value && !linkedPlayback.isConnected) {
      linkedPlayback.wake();
    } else {
      linkedPlayback
        ..toggleSync()
        ..wake();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final on = linkedPlayback.syncOn.value;
      final connected = linkedPlayback.isConnected;
      return Tooltip(
        message: on
            ? connected
                  ? '关闭同步播放'
                  : '同步播放（未连接，点击重连）'
            : '开启同步播放',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: SizedBox(
            width: widths.sync,
            height: LinkedBarControls._height,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: _Widths._spacing,
              children: [
                Opacity(
                  opacity: on && !connected ? 0.5 : 1,
                  child: SizedBox(
                    width: _Widths._switchWidth,
                    height: 24,
                    child: FittedBox(
                      child: Switch(
                        value: on,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onChanged: (_) => _onTap(),
                      ),
                    ),
                  ),
                ),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      on && !connected ? '未连接' : '同步',
                      maxLines: 1,
                      style: _textStyle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// 延迟偏移：当前值、横向拨轮（每格 0.5ms）、归零
class _LinkedOffsetControl extends StatelessWidget {
  const _LinkedOffsetControl({
    required this.widths,
    required this.onInteraction,
    required this.onDragging,
  });

  final _Widths widths;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onDragging;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widths.offset,
      height: LinkedBarControls._height,
      child: Row(
        children: [
          SizedBox(
            width: widths.offsetValue,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Obx(
                () => Text(
                  formatLinkedOffset(linkedPlayback.offsetUs.value),
                  maxLines: 1,
                  style: _textStyle,
                ),
              ),
            ),
          ),
          const SizedBox(width: _Widths._spacing),
          LinkedOffsetDial(
            axis: Axis.horizontal,
            length: _Widths._offsetDial,
            thickness: 26,
            onInteraction: onInteraction,
            onDragging: onDragging,
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onInteraction();
                linkedPlayback.setOffset(0);
              },
              child: const Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('归零', maxLines: 1, style: _dimTextStyle),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 跟随端音量：模式切换（跟随主控 / 独立）与对应的调节；主控端调节在线的
/// 跟随端，多台时点击设备名依次切换
class _LinkedVolumeControl extends StatefulWidget {
  const _LinkedVolumeControl({
    required this.widths,
    required this.onInteraction,
    required this.onDragging,
    this.stacked = false,
  });

  final _Widths widths;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onDragging;

  /// 在弹出层中：设备名单独一行
  final bool stacked;

  /// 可调节音量的跟随端数量：跟随端为本机
  static int get peerCount => linkedPlayback.role.value == LinkedRole.follower
      ? 1
      : _peers.length;

  static List<LinkedPeerInfo> get _peers => [
    for (final peer in linkedPlayback.peers)
      if (peer.state != LinkedPeerState.offline && peer.volume != null) peer,
  ];

  @override
  State<_LinkedVolumeControl> createState() => _LinkedVolumeControlState();
}

class _LinkedVolumeControlState extends State<_LinkedVolumeControl> {
  /// 主控端当前调节的跟随端
  static String? _selectedId;

  static String _signed(int value) => '${value > 0 ? '+' : ''}$value';

  Widget _modeToggle(LinkedVolume volume, ValueChanged<LinkedVolume> onChanged) {
    // 字体放大时随文本增高，再由外层整体缩小到底栏高度内
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white38),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final mode in LinkedVolumeMode.values)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.onInteraction();
                  if (mode != volume.mode) {
                    onChanged(
                      volume.switchTo(mode, linkedPlayback.leaderVolume.value),
                    );
                  }
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: mode == volume.mode
                        ? Colors.white.withValues(alpha: 0.25)
                        : null,
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _Widths._modePadding,
                    ),
                    child: Center(
                      child: Text(
                        mode.label,
                        maxLines: 1,
                        style: mode == volume.mode ? _textStyle : _dimTextStyle,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _adjust(LinkedVolume volume, ValueChanged<LinkedVolume> onChanged) {
    final follow = volume.mode == LinkedVolumeMode.follow;
    final index = follow ? volume.offset : (volume.level * 100).round();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.widths.volumeValue,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              follow ? _signed(volume.offset) : '$index%',
              maxLines: 1,
              style: _textStyle,
            ),
          ),
        ),
        const SizedBox(width: _Widths._spacing),
        LinkedDial(
          index: index,
          axis: Axis.horizontal,
          length: _Widths._volumeDial,
          thickness: 26,
          onInteraction: widget.onInteraction,
          onDragging: widget.onDragging,
          onSteps: (steps) => onChanged(
            follow
                ? volume.copyWith(
                    offset: (volume.offset + steps).clamp(-100, 100),
                  )
                : volume.copyWith(
                    level: ((index + steps).clamp(0, 100)) / 100,
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final LinkedVolume volume;
      final ValueChanged<LinkedVolume> onChanged;
      LinkedPeerInfo? peer;
      List<LinkedPeerInfo> peers = const [];
      if (linkedPlayback.role.value == LinkedRole.follower) {
        volume = linkedPlayback.volume.value;
        onChanged = (value) => linkedPlayback.setVolume(null, value);
      } else {
        peers = _LinkedVolumeControl._peers;
        if (peers.isEmpty) return const SizedBox.shrink();
        var selected = peers.first;
        for (final item in peers) {
          if (item.id == _selectedId) selected = item;
        }
        peer = selected;
        final id = selected.id;
        volume = selected.volume!;
        onChanged = (value) => linkedPlayback.setVolume(id, value);
      }
      final peerChip = peers.length > 1
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.onInteraction();
                final next = (peers.indexOf(peer!) + 1) % peers.length;
                setState(() => _selectedId = peers[next].id);
              },
              child: SizedBox(
                width: LinkedBarControls._peerWidth,
                height: LinkedBarControls._height,
                child: Row(
                  children: [
                    const Icon(
                      Icons.swap_horiz_rounded,
                      size: 14,
                      color: Colors.white70,
                    ),
                    Expanded(
                      child: Text(
                        peer!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _dimTextStyle,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null;
      final controls = SizedBox(
        width: widget.widths.volume,
        height: LinkedBarControls._height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: _Widths._spacing,
          children: [
            const Icon(
              Icons.volume_up_outlined,
              size: _Widths._volumeIcon,
              color: Colors.white,
            ),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _modeToggle(volume, onChanged),
              ),
            ),
            _adjust(volume, onChanged),
          ],
        ),
      );
      if (peerChip == null) return controls;
      return widget.stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [peerChip, controls],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: LinkedBarControls._gap,
              children: [peerChip, controls],
            );
    });
  }
}
