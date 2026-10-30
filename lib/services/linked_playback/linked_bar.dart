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
  static const double _syncWidth = 78;
  static const double _offsetWidth = 204;
  static const double _volumeWidth = 256;
  static const double _peerWidth = 64;

  /// 本播放器：只在其内容是联动的内容时显示偏移与音量
  final PlPlayerController controller;

  /// 操作期间调用，保持播放器控件显示
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final current = linkedPlayback.current.value;
      // 登记内容先于播放器更新分P，加载完成后再按分P核对
      controller.dataStatus.value;
      final cid = controller.cid;
      final adjust =
          linkedPlayback.syncOn.value &&
          current?.kind == LinkedKind.video &&
          current?.cid == cid;
      final volumePeers = _LinkedVolumeControl.peerCount;
      final volume = adjust && volumePeers > 0;
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final volumeWidth =
              _volumeWidth + (volumePeers > 1 ? _peerWidth + _gap : 0);
          final List<Widget> children;
          if (!adjust) {
            children = [
              if (width >= _syncWidth)
                const _LinkedSyncSwitch()
              else
                _panelButton(sync: true, adjust: false, volume: false),
            ];
          } else if (width >=
              _syncWidth +
                  _gap +
                  _offsetWidth +
                  (volume ? _gap + volumeWidth : 0)) {
            children = [
              if (volume) _LinkedVolumeControl(onInteraction: onInteraction),
              _LinkedOffsetControl(onInteraction: onInteraction),
              const _LinkedSyncSwitch(),
            ];
          } else if (volume &&
              width >= _syncWidth + _gap + _offsetWidth + _gap + _buttonWidth) {
            children = [
              _panelButton(sync: false, adjust: false, volume: true),
              _LinkedOffsetControl(onInteraction: onInteraction),
              const _LinkedSyncSwitch(),
            ];
          } else if (width >= _syncWidth + _gap + _buttonWidth) {
            children = [
              _panelButton(sync: false, adjust: true, volume: volume),
              const _LinkedSyncSwitch(),
            ];
          } else {
            children = [
              _panelButton(sync: true, adjust: true, volume: volume),
            ];
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

  /// 收起的控件：点击后在弹出层中显示
  Widget _panelButton({
    required bool sync,
    required bool adjust,
    required bool volume,
  }) {
    return PopupMenuButton<void>(
      tooltip: sync ? '联动播放' : (adjust ? '联动调节' : '跟随端音量'),
      requestFocus: false,
      color: Colors.black.withValues(alpha: 0.8),
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
      onOpened: onInteraction,
      itemBuilder: (context) => [
        _PanelEntry(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 6,
            children: [
              if (sync) const _LinkedSyncSwitch(),
              if (adjust) _LinkedOffsetControl(onInteraction: onInteraction),
              if (volume)
                _LinkedVolumeControl(
                  onInteraction: onInteraction,
                  stacked: true,
                ),
            ],
          ),
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
                  adjust ? Icons.tune_rounded : Icons.volume_up_outlined,
                  size: 20,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }
}

/// 弹出层中不可选的整块内容
class _PanelEntry extends PopupMenuEntry<void> {
  const _PanelEntry({required this.child});

  final Widget child;

  @override
  double get height => LinkedBarControls._height;

  @override
  bool represents(void value) => false;

  @override
  State<_PanelEntry> createState() => _PanelEntryState();
}

class _PanelEntryState extends State<_PanelEntry> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: widget.child,
  );
}

/// 同步开关：两端共用；已开启但未连接时点击只重连，不改动开关
class _LinkedSyncSwitch extends StatelessWidget {
  const _LinkedSyncSwitch();

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
            width: LinkedBarControls._syncWidth,
            height: LinkedBarControls._height,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 4,
              children: [
                Opacity(
                  opacity: on && !connected ? 0.5 : 1,
                  child: SizedBox(
                    width: 38,
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
                Text(on && !connected ? '未连接' : '同步', style: _textStyle),
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
  const _LinkedOffsetControl({required this.onInteraction});

  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: LinkedBarControls._offsetWidth,
      height: LinkedBarControls._height,
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Obx(
              () => Text(
                formatLinkedOffset(linkedPlayback.offsetUs.value),
                textAlign: TextAlign.right,
                maxLines: 1,
                style: _textStyle,
              ),
            ),
          ),
          const SizedBox(width: 4),
          LinkedOffsetDial(
            axis: Axis.horizontal,
            length: 104,
            thickness: 26,
            onInteraction: onInteraction,
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onInteraction();
                linkedPlayback.setOffset(0);
              },
              child: const Center(child: Text('归零', style: _dimTextStyle)),
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
    required this.onInteraction,
    this.stacked = false,
  });

  final VoidCallback onInteraction;

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
    return Container(
      height: 24,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white38),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  child: Center(
                    child: Text(
                      mode.label,
                      style: mode == volume.mode ? _textStyle : _dimTextStyle,
                    ),
                  ),
                ),
              ),
            ),
        ],
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
          width: 40,
          child: Text(
            follow ? _signed(volume.offset) : '$index%',
            textAlign: TextAlign.right,
            maxLines: 1,
            style: _textStyle,
          ),
        ),
        const SizedBox(width: 4),
        LinkedDial(
          index: index,
          axis: Axis.horizontal,
          length: 84,
          thickness: 26,
          onInteraction: widget.onInteraction,
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
        peer = peers.first;
        for (final item in peers) {
          if (item.id == _selectedId) peer = item;
        }
        final id = peer.id;
        volume = peer.volume!;
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
        width: LinkedBarControls._volumeWidth,
        height: LinkedBarControls._height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: 4,
          children: [
            const Icon(Icons.volume_up_outlined, size: 18, color: Colors.white),
            _modeToggle(volume, onChanged),
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
