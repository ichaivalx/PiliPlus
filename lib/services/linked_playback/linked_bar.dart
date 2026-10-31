import 'dart:math' as math;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/linked_playback/offset_dial.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const _textStyle = TextStyle(color: Colors.white, fontSize: 12);
const _dimTextStyle = TextStyle(color: Colors.white70, fontSize: 11);

/// 播放器底栏中的联动控件，从左到右为当前调节的跟随端（主控有多台跟随端时）、
/// 跟随端音量（模式切换与竖向拨轮）、延迟偏移（拨轮与归零）、同步开关；偏移与
/// 音量都作用于当前调节的跟随端。放得下时全部展开，多出的宽度加长偏移拨轮；
/// 放不下时依次把音量、调节部分（含跟随端切换）收进按钮弹出，最窄时整体收为
/// 一个按钮
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

  /// 联动已开启且本播放器的内容是联动的内容（番剧、直播、互动视频等不联动的
  /// 内容不显示）；在 Obx 中调用
  static bool showsFor(PlPlayerController controller) =>
      linkedPlayback.enabled.value && _state(controller).linkable;

  /// 是否联动的内容、可调节偏移与音量的跟随端数量（同步关闭时为 0，跟随端为
  /// 本机）；在 Obx 中调用
  static ({bool linkable, int peers}) _state(PlPlayerController controller) {
    final current = linkedPlayback.current.value;
    // 登记内容先于播放器更新分P，加载完成后再按分P核对
    controller.dataStatus.value;
    final linkable =
        current?.kind == LinkedKind.video && current?.cid == controller.cid;
    final int peers;
    if (!linkable || !linkedPlayback.syncOn.value) {
      peers = 0;
    } else if (linkedPlayback.role.value == LinkedRole.follower) {
      peers = 1;
    } else {
      peers = linkedPlayback.adjustablePeers.length;
    }
    return (linkable: linkable, peers: peers);
  }

  @override
  Widget build(BuildContext context) {
    final widths = _Widths.of(context);
    return Obx(() {
      final (:linkable, :peers) = _state(controller);
      if (!linkable) return const SizedBox.shrink();
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final peer = peers > 1 ? _peerWidth + _gap : 0.0;
          // 偏移拨轮取最短时，偏移及其右侧所需的宽度
          final offset =
              widths.offsetFor(_Widths._minOffsetDial) + _gap + widths.sync;
          final full = peer + widths.volume + _gap + offset;
          final volumeCollapsed = peer + _buttonWidth + _gap + offset;
          final List<Widget> children;
          if (peers == 0) {
            children = [
              if (width >= widths.sync)
                _LinkedSyncSwitch(widths: widths)
              else
                _panelButton(widths, sync: true, offset: true),
            ];
          } else if (width >= volumeCollapsed) {
            final expanded = width >= full;
            final dial = math.min(
              _Widths._maxOffsetDial,
              _Widths._minOffsetDial +
                  width -
                  (expanded ? full : volumeCollapsed),
            );
            children = [
              if (peers > 1) _LinkedPeerChip(onInteraction: onInteraction),
              if (expanded)
                _LinkedVolumeControl(
                  widths: widths,
                  onInteraction: onInteraction,
                  onDragging: _onDragging,
                )
              else
                _panelButton(widths, sync: false, offset: false),
              _LinkedOffsetControl(
                widths: widths,
                dial: dial,
                onInteraction: onInteraction,
                onDragging: _onDragging,
              ),
              _LinkedSyncSwitch(widths: widths),
            ];
          } else if (width >= _buttonWidth + _gap + widths.sync) {
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

  /// 收起的控件：点击后在弹出层中显示；[sync] 含同步开关，[offset] 含偏移（及
  /// 多台跟随端时的切换），音量总在其中；偏移、音量按实时的联动状态显示（如
  /// 弹出层内开启同步后出现）
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
    required this.slower,
    required this.faster,
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
      slower: measure(linkedSlowerLabel, _dimTextStyle),
      faster: measure(linkedFasterLabel, _dimTextStyle),
      offsetValue: math.max(
        56.0,
        math.max(
          measure(formatLinkedOffset(88500), _textStyle),
          measure(formatLinkedOffset(-88500), _textStyle),
        ),
      ),
      offsetZero: math.max(36.0, measure('归零', _dimTextStyle) + 12),
      toggle: toggle,
      volumeValue: math.max(
        32.0,
        math.max(measure('100%', _textStyle), measure('+100', _textStyle)),
      ),
    );
  }

  static const double _switchWidth = 38;
  static const double _spacing = 4;
  static const double _modePadding = 7;

  /// 偏移拨轮的长度范围：底栏中在放得下的前提下尽量长，弹出层中取最长
  static const double _minOffsetDial = 72;
  static const double _maxOffsetDial = 120;

  /// 竖向音量拨轮的粗细，长度为底栏高度
  static const double _volumeDial = 22;
  static const double _volumeIcon = 16;

  final double sync;

  /// 偏移拨轮两端的文本、偏移值文本与归零按钮
  final double slower;
  final double faster;
  final double offsetValue;
  final double offsetZero;

  /// 音量模式切换
  final double toggle;

  /// 音量值文本
  final double volumeValue;

  /// 偏移拨轮长为 [dial] 时偏移部分的宽度
  double offsetFor(double dial) =>
      slower +
      _spacing +
      dial +
      _spacing +
      faster +
      _spacing +
      offsetValue +
      _spacing +
      offsetZero;

  double get volume =>
      _volumeIcon +
      _spacing +
      toggle +
      _spacing +
      volumeValue +
      _spacing +
      _volumeDial;

  /// 弹出层内容
  double get panel => math.max(
    math.max(sync, LinkedBarControls._peerWidth),
    math.max(offsetFor(_maxOffsetDial), volume),
  );
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
      // 锁定播放器后不再可操作
      if (widget.controller.controlsLock.value) {
        _close(route);
        return const SizedBox.shrink();
      }
      final (:linkable, :peers) = LinkedBarControls._state(widget.controller);
      final children = [
        if (widget.offset && peers > 1)
          _LinkedPeerChip(onInteraction: widget.onInteraction),
        if (peers > 0)
          _LinkedVolumeControl(
            widths: widths,
            onInteraction: widget.onInteraction,
            onDragging: widget.onDragging,
          ),
        if (widget.offset && peers > 0)
          _LinkedOffsetControl(
            widths: widths,
            dial: _Widths._maxOffsetDial,
            onInteraction: widget.onInteraction,
            onDragging: widget.onDragging,
          ),
        if (widget.sync && linkable) _LinkedSyncSwitch(widths: widths),
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

/// 延迟偏移：两端标注快慢的横向拨轮（每格 0.5ms）、当前值、归零
class _LinkedOffsetControl extends StatelessWidget {
  const _LinkedOffsetControl({
    required this.widths,
    required this.dial,
    required this.onInteraction,
    required this.onDragging,
  });

  final _Widths widths;

  /// 拨轮长度
  final double dial;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onDragging;

  static Widget _label(double width, String text, TextStyle style) => SizedBox(
    width: width,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1, style: style),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widths.offsetFor(dial),
      height: LinkedBarControls._height,
      child: Row(
        spacing: _Widths._spacing,
        children: [
          _label(widths.slower, linkedSlowerLabel, _dimTextStyle),
          LinkedOffsetDial(
            axis: Axis.horizontal,
            length: dial,
            thickness: 26,
            onInteraction: onInteraction,
            onDragging: onDragging,
          ),
          _label(widths.faster, linkedFasterLabel, _dimTextStyle),
          Obx(
            () => _label(
              widths.offsetValue,
              formatLinkedOffset(linkedPlayback.currentOffsetUs ?? 0),
              _textStyle,
            ),
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

/// 主控有多台跟随端时当前调节的跟随端（偏移与音量共用），点击依次切换
class _LinkedPeerChip extends StatelessWidget {
  const _LinkedPeerChip({required this.onInteraction});

  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final peers = linkedPlayback.adjustablePeers;
      final peer = linkedPlayback.selectedPeer;
      if (peers.length < 2 || peer == null) return const SizedBox.shrink();
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          onInteraction();
          final index = peers.indexWhere((e) => e.id == peer.id);
          linkedPlayback.selectPeer(peers[(index + 1) % peers.length].id);
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
                  peer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _dimTextStyle,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// 跟随端音量：模式切换（跟随主控 / 独立）与对应的调节；主控端调节当前的
/// 跟随端
class _LinkedVolumeControl extends StatefulWidget {
  const _LinkedVolumeControl({
    required this.widths,
    required this.onInteraction,
    required this.onDragging,
  });

  final _Widths widths;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onDragging;

  @override
  State<_LinkedVolumeControl> createState() => _LinkedVolumeControlState();
}

class _LinkedVolumeControlState extends State<_LinkedVolumeControl> {
  static String _signed(int value) => '${value > 0 ? '+' : ''}$value';

  /// 拖动或连续滚动滚轮期间已提交给设备 [id] 的音量：重建前连续多次更新也在其上
  /// 逐格累加，调节结束后清除；调节的设备变化（含所选设备离线后自动改选）时拨轮
  /// 随设备重建，当前调节随之结束；模式变化时不再沿用
  ({String? id, LinkedVolume volume})? _dragVolume;

  void _onDragging(bool dragging) {
    if (!dragging) _dragVolume = null;
    widget.onDragging(dragging);
  }

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
                  _dragVolume = null;
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

  Widget _adjust(
    String? id,
    LinkedVolume volume,
    ValueChanged<LinkedVolume> onChanged,
  ) {
    final leader = linkedPlayback.leaderVolume.value;
    // 跟随主控时显示实际生效的音量，主控音量未知时只能显示偏移
    final target = volume.targetFor(leader);
    final index = target == null ? volume.offset : (target * 100).round();
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: _Widths._spacing,
      children: [
        SizedBox(
          width: widget.widths.volumeValue,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              target == null ? _signed(volume.offset) : '$index%',
              maxLines: 1,
              style: _textStyle,
            ),
          ),
        ),
        LinkedDial(
          key: ValueKey<String?>(id),
          index: index,
          axis: Axis.vertical,
          length: LinkedBarControls._height,
          thickness: _Widths._volumeDial,
          onInteraction: widget.onInteraction,
          onDragging: _onDragging,
          onSteps: (steps) {
            final pending = _dragVolume;
            final base =
                pending != null &&
                    pending.id == id &&
                    pending.volume.mode == volume.mode
                ? pending.volume
                : volume;
            final LinkedVolume next;
            if (base.mode == LinkedVolumeMode.follow) {
              // 主控音量已知时偏移只在生效音量 0~100% 内调节，每格都有变化
              final percent = leader == null ? 0 : (leader * 100).round();
              final low = leader == null ? -100 : math.max(-100, -percent);
              final high = leader == null ? 100 : math.min(100, 100 - percent);
              next = base.copyWith(
                offset: (base.offset + steps).clamp(low, high),
              );
            } else {
              next = base.copyWith(
                level: ((base.level * 100).round() + steps).clamp(0, 100) / 100,
              );
            }
            _dragVolume = (id: id, volume: next);
            onChanged(next);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final LinkedVolume volume;
      final ValueChanged<LinkedVolume> onChanged;
      String? id;
      if (linkedPlayback.role.value == LinkedRole.follower) {
        volume = linkedPlayback.volume.value;
        onChanged = (value) => linkedPlayback.setVolume(null, value);
      } else {
        final peer = linkedPlayback.selectedPeer;
        if (peer == null) return const SizedBox.shrink();
        final selectedId = id = peer.id;
        volume = peer.volume!;
        onChanged = (value) => linkedPlayback.setVolume(selectedId, value);
      }
      return SizedBox(
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
            _adjust(id, volume, onChanged),
          ],
        ),
      );
    });
  }
}
