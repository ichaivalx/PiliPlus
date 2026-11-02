import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/linked_playback/calibration_panel.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/linked_playback/offset_dial.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const _textStyle = TextStyle(color: Colors.white, fontSize: 12);
const _dimValueStyle = TextStyle(color: Colors.white70, fontSize: 12);
const _dimTextStyle = TextStyle(color: Colors.white70, fontSize: 11);

const _zeroLabel = '归零';
const _calibrateLabel = '校准';

/// 播放器底栏中的联动控件。从左到右分组：当前调节的跟随端（主控）、跟随端音量（模式
/// 切换、数值与竖向拨轮）、延迟偏移（拨轮与数值）、归零与校准（校准仅主控）、同步开关；
/// 偏移与音量都作用于当前调节的跟随端。组内、组间（含与两侧的底栏控件之间）各用统一的
/// 间距。全部平铺：多出的宽度先加长偏移拨轮至上限，再加宽组间距至上限，其余留在
/// 左侧，控件整体靠右（与定时关闭之间仍为一个组间距）；宽度不足时依次
/// 缩短偏移拨轮、收紧间距、改用短文案，仍放不下时才依次把音量、调节部分收进按钮弹出，
/// 最窄时整体收为一个按钮
class LinkedBarControls extends StatelessWidget {
  const LinkedBarControls({
    super.key,
    required this.controller,
    required this.onInteraction,
  });

  /// 整体收为一个按钮时的宽度，底栏至少为此预留；更窄时不显示
  static const double minWidth = _Size.button;

  /// 本播放器：只在其内容是联动的内容时显示偏移与音量
  final PlPlayerController controller;

  /// 操作期间调用，保持播放器控件显示
  final VoidCallback onInteraction;

  /// 拨动结束后继续保持控件显示的时长，便于拨完听一会再决定，之后照常计时隐藏
  static const _lingerAfterDial = Duration(seconds: 3);

  /// 拖动拨轮期间及结束后 [_lingerAfterDial] 内不自动隐藏播放器控件
  void _onDragging(bool dragging) {
    if (dragging) {
      controller.holdControls();
    } else {
      Timer(_lingerAfterDial, controller.releaseControls);
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

  /// 各控件的宽度；在 Obx 中调用
  static _Groups _groups(_Metrics metrics) {
    final leader = linkedPlayback.role.value == LinkedRole.leader;
    return _Groups(
      metrics: metrics,
      names: leader
          ? [for (final peer in linkedPlayback.adjustablePeers) peer.name]
          : null,
      calibrate: leader,
      sync: metrics.sync(_LinkedSyncSwitch.label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _Metrics.of(context);
    return Obx(() {
      final (:linkable, :peers) = _state(controller);
      if (!linkable) return const SizedBox.shrink();
      final groups = _groups(metrics);
      // 主控有跟随端但同步关闭：调节控件不显示，校准按钮仍可打开校准面板
      final idleCalibrate =
          groups.calibrate &&
          peers == 0 &&
          !linkedPlayback.syncOn.value &&
          linkedPlayback.adjustablePeers.isNotEmpty;
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final double group;
          final List<(Widget, double)> items;
          if (peers > 0) {
            final layout = groups.solve(width);
            if (layout == null) return const SizedBox.shrink();
            group = layout.group;
            items = _items(groups, layout);
          } else if (width >= groups.sync + 2 * _Size.group) {
            final calibrate = metrics.button(_calibrateLabel);
            group = _Size.group;
            items = [
              if (idleCalibrate &&
                  width >=
                      calibrate +
                          groups.sync +
                          3 * _Size.group -
                          2 * _Size.textInset)
                (
                  _LinkedCalibrateButton(
                    metrics: metrics,
                    onInteraction: onInteraction,
                  ),
                  _Size.textInset,
                ),
              (_LinkedSyncSwitch(width: groups.sync), 0.0),
            ];
          } else if (width >= _Size.button) {
            group = math.min(_Size.tightGroup, (width - _Size.button) / 2);
            items = [(_panelButton(groups, sync: true, offset: true), 0.0)];
          } else {
            return const SizedBox.shrink();
          }
          return SizedBox(
            height: _Size.height,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: _spaced(items, group),
            ),
          );
        },
      );
    });
  }

  /// 按 [layout] 排布的各组控件与其两侧的透明边距
  List<(Widget, double)> _items(_Groups groups, _Layout layout) {
    final collapse = layout.collapse;
    if (collapse == _Collapse.all) {
      return [(_panelButton(groups, sync: true, offset: true), 0.0)];
    }
    return [
      if (collapse == _Collapse.adjust)
        (_panelButton(groups, sync: false, offset: true), 0.0)
      else ...[
        if (groups.names != null)
          (
            _LinkedPeerChip(
              width: groups.device(layout.short),
              onInteraction: onInteraction,
            ),
            0.0,
          ),
        if (collapse == _Collapse.volume)
          (_panelButton(groups, sync: false, offset: false), 0.0)
        else
          (
            _LinkedVolumeControl(
              groups: groups,
              layout: layout,
              onInteraction: onInteraction,
              onDragging: _onDragging,
            ),
            0.0,
          ),
        (
          _LinkedOffsetControl(
            groups: groups,
            layout: layout,
            onInteraction: onInteraction,
            onDragging: _onDragging,
          ),
          0.0,
        ),
        (
          _LinkedOffsetButtons(
            groups: groups,
            layout: layout,
            onInteraction: onInteraction,
          ),
          _Size.textInset,
        ),
      ],
      (_LinkedSyncSwitch(width: groups.sync), 0.0),
    ];
  }

  /// 各组之间与两端加上组间距 [group]，扣除文字按钮的透明边距，使看到的间距一致；
  /// 最左侧的间距可被压缩，吸收小数误差
  static List<Widget> _spaced(List<(Widget, double)> items, double group) {
    final children = <Widget>[];
    var previous = 0.0;
    for (final (child, inset) in items) {
      final gap = SizedBox(width: math.max(0.0, group - previous - inset));
      children
        ..add(children.isEmpty ? Flexible(child: gap) : gap)
        ..add(child);
      previous = inset;
    }
    children.add(SizedBox(width: math.max(0.0, group - previous)));
    return children;
  }

  /// 收起的控件：点击后在弹出层中显示；[sync] 含同步开关，[offset] 含偏移（及
  /// 主控的跟随端），音量总在其中；偏移、音量按实时的联动状态显示（如弹出层内
  /// 开启同步后出现）
  Widget _panelButton(
    _Groups groups, {
    required bool sync,
    required bool offset,
  }) {
    return PopupMenuButton<void>(
      tooltip: sync ? '联动播放' : (offset ? '联动调节' : '跟随端音量'),
      requestFocus: false,
      color: Colors.black.withValues(alpha: 0.8),
      constraints: BoxConstraints(
        minWidth: 260,
        maxWidth: math.max(320.0, groups.panel + 2 * _PanelEntry._padding),
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
        width: _Size.button,
        height: _Size.height,
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

/// 尺寸与间距
abstract final class _Size {
  static const double height = 34;

  /// 收起的按钮
  static const double button = 40;

  /// 组内间距，宽度不足时收紧到 [tightInner]
  static const double inner = 6;
  static const double tightInner = 4;

  /// 组间距（含与两侧的底栏控件之间），宽度不足时收紧到 [tightGroup]；宽度有余时
  /// 均分加宽，至多 [maxGroup]
  static const double group = 14;
  static const double tightGroup = 8;
  static const double maxGroup = 24;

  /// 偏移拨轮的长度：宽度有余时先加长到 [maxDial]，不足时先缩短到 [minDial]
  static const double minDial = 56;
  static const double maxDial = 120;

  /// 竖向音量拨轮的宽度，按手指按住时两侧仍能露出刻度
  static const double volumeDial = 48;

  /// 音量图标与跟随端切换图标
  static const double icon = 16;
  static const double iconGap = 4;

  /// 跟随端名称最宽的宽度，过长时省略；短文案时为 [shortName]
  static const double name = 80;
  static const double shortName = 48;

  /// 文字按钮在文字两侧的点击边距
  static const double textInset = 4;

  static const double switchWidth = 38;
  static const double switchGap = 4;

  /// 音量模式切换中每项文字两侧的边距
  static const double modePadding = 7;
}

/// 收起的程度
enum _Collapse {
  /// 全部平铺
  none,

  /// 音量收进按钮
  volume,

  /// 跟随端、音量、偏移与归零、校准收进按钮，只留同步开关
  adjust,

  /// 整体收为一个按钮
  all,
}

/// 一种排布：组内间距 [inner]、组间距 [group]、偏移拨轮长度 [dial]、是否用短
/// 文案 [short]
class _Layout {
  const _Layout({
    required this.collapse,
    required this.short,
    this.inner = _Size.inner,
    this.group = _Size.group,
    this.dial = _Size.minDial,
  });

  final _Collapse collapse;
  final bool short;
  final double inner;
  final double group;
  final double dial;

  _Layout copyWith({double? inner, double? group, double? dial}) => _Layout(
    collapse: collapse,
    short: short,
    inner: inner ?? this.inner,
    group: group ?? this.group,
    dial: dial ?? this.dial,
  );
}

/// 文本宽度：按当前字体、缩放与粗体设置实际排版量出
class _Metrics {
  _Metrics._(this._base, this._scaler);

  factory _Metrics.of(BuildContext context) {
    var base = DefaultTextStyle.of(context).style;
    if (MediaQuery.boldTextOf(context)) {
      base = base.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return _Metrics._(base, MediaQuery.textScalerOf(context));
  }

  final TextStyle _base;
  final TextScaler _scaler;
  final _cache = <(String, TextStyle), double>{};

  double measure(String text, TextStyle style) =>
      _cache[(text, style)] ??= () {
        final painter = TextPainter(
          text: TextSpan(text: text, style: _base.merge(style)),
          textDirection: TextDirection.ltr,
          textScaler: _scaler,
          maxLines: 1,
        )..layout();
        final width = painter.width.ceilToDouble();
        painter.dispose();
        return width;
      }();

  /// 偏移拨轮两端的文本
  double slower(bool short) => measure(
    short ? linkedSlowerShortLabel : linkedSlowerLabel,
    _dimTextStyle,
  );
  double faster(bool short) => measure(
    short ? linkedFasterShortLabel : linkedFasterLabel,
    _dimTextStyle,
  );

  /// 音量模式切换
  double toggle(bool short) {
    var width = 2.0;
    for (final mode in LinkedVolumeMode.values) {
      width +=
          measure(short ? mode.shortLabel : mode.label, _textStyle) +
          2 * _Size.modePadding;
    }
    return width;
  }

  /// 音量值
  late final double volumeValue = math.max(
    measure('100%', _textStyle),
    math.max(measure('+100', _textStyle), measure('-100', _textStyle)),
  );

  /// 偏移值
  late final double offsetValue = math.max(
    measure(formatLinkedOffset(88500), _textStyle),
    measure(formatLinkedOffset(-88500), _textStyle),
  );

  /// 文字按钮
  double button(String text) =>
      measure(text, _dimTextStyle) + 2 * _Size.textInset;

  /// 文字为 [label] 的同步开关
  double sync(String label) =>
      _Size.switchWidth + _Size.switchGap + measure(label, _textStyle);
}

/// 各组控件的宽度与排布
class _Groups {
  const _Groups({
    required this.metrics,
    required this.names,
    required this.calibrate,
    required this.sync,
  });

  final _Metrics metrics;

  /// 主控可调节的各跟随端的名称；跟随端为 null，不显示当前调节的跟随端
  final List<String>? names;

  /// 主控的校准按钮
  final bool calibrate;

  /// 同步开关
  final double sync;

  /// 跟随端名称：按最长的名称，过长时省略，切换跟随端时其余控件不跳动
  double name(bool short) {
    var width = 0.0;
    for (final name in names ?? const <String>[]) {
      width = math.max(width, metrics.measure(name, _textStyle));
    }
    return math.min(width, short ? _Size.shortName : _Size.name);
  }

  /// 当前调节的跟随端：切换图标与名称
  double device(bool short) => _Size.icon + _Size.iconGap + name(short);

  double volume(_Layout layout) =>
      _Size.icon +
      metrics.toggle(layout.short) +
      metrics.volumeValue +
      _Size.volumeDial +
      3 * layout.inner;

  double offset(_Layout layout) =>
      metrics.slower(layout.short) +
      metrics.faster(layout.short) +
      metrics.offsetValue +
      layout.dial +
      3 * layout.inner;

  /// 归零与校准相邻的一侧各以组内间距的一半为点击边距，看到的间距与组内一致
  double buttons(_Layout layout) =>
      metrics.button(_zeroLabel) +
      (calibrate
          ? metrics.button(_calibrateLabel) +
                layout.inner -
                2 * _Size.textInset
          : 0);

  /// 各组的宽度与两侧的透明边距
  List<(double, double)> _widths(_Layout layout) => switch (layout.collapse) {
    _Collapse.all => const [(_Size.button, 0.0)],
    _Collapse.adjust => [(_Size.button, 0.0), (sync, 0.0)],
    _ => [
      if (names != null) (device(layout.short), 0.0),
      (
        layout.collapse == _Collapse.volume ? _Size.button : volume(layout),
        0.0,
      ),
      (offset(layout), 0.0),
      (buttons(layout), _Size.textInset),
      (sync, 0.0),
    ],
  };

  /// 含两端在内的总宽度
  double total(_Layout layout) {
    final widths = _widths(layout);
    var total = (widths.length + 1) * layout.group;
    for (final (width, inset) in widths) {
      total += width - 2 * inset;
    }
    return total;
  }

  /// 宽度为 [width] 时的排布：依次缩短偏移拨轮、收紧间距、改用短文案，仍放不下
  /// 时依次收起音量、调节部分，最后整体收起（两侧间距可压缩到 0）；连收起的按钮
  /// 都放不下时为 null，不显示
  _Layout? solve(double width) {
    for (final collapse in _Collapse.values) {
      for (final short
          in collapse == _Collapse.none ? const [false, true] : const [true]) {
        if (_fit(width, _Layout(collapse: collapse, short: short))
            case final layout?) {
          return layout;
        }
      }
    }
    if (width < _Size.button) return null;
    return _Layout(
      collapse: _Collapse.all,
      short: true,
      inner: _Size.tightInner,
      group: (width - _Size.button) / 2,
    );
  }

  /// [loose] 为常规间距与最短的偏移拨轮：宽度有余时先加长拨轮，再均分加宽各组
  /// 间距至上限，其余不占用；不足时按比例收紧间距，收紧到底仍放不下为 null
  _Layout? _fit(double width, _Layout loose) {
    final normal = total(loose);
    final dialRange = loose.collapse.index <= _Collapse.volume.index
        ? _Size.maxDial - _Size.minDial
        : 0.0;
    if (width >= normal + dialRange) {
      return loose.copyWith(
        dial: _Size.maxDial,
        group: math.min(
          _Size.maxGroup,
          _Size.group +
              (width - normal - dialRange) / (_widths(loose).length + 1),
        ),
      );
    }
    if (width >= normal) {
      return loose.copyWith(dial: _Size.minDial + width - normal);
    }
    final tight = total(
      loose.copyWith(inner: _Size.tightInner, group: _Size.tightGroup),
    );
    if (width < tight) return null;
    final t = (normal - width) / (normal - tight);
    return loose.copyWith(
      inner: _Size.inner + (_Size.tightInner - _Size.inner) * t,
      group: _Size.group + (_Size.tightGroup - _Size.group) * t,
    );
  }

  /// 弹出层中按常规间距、最长的偏移拨轮排布
  static const panelLayout = _Layout(
    collapse: _Collapse.none,
    short: false,
    dial: _Size.maxDial,
  );

  /// 弹出层内容的宽度
  double get panel => math.max(
    math.max(device(false), sync),
    math.max(
      volume(panelLayout),
      offset(panelLayout) + panelLayout.inner + buttons(panelLayout),
    ),
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
  double get height => _Size.height;

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
    final metrics = _Metrics.of(context);
    final route = ModalRoute.of(context);
    return Obx(() {
      // 锁定播放器后不再可操作
      if (widget.controller.controlsLock.value) {
        _close(route);
        return const SizedBox.shrink();
      }
      final (:linkable, :peers) = LinkedBarControls._state(widget.controller);
      final groups = LinkedBarControls._groups(metrics);
      const layout = _Groups.panelLayout;
      final children = [
        if (widget.offset && peers > 0 && groups.names != null)
          _LinkedPeerChip(
            width: groups.device(false),
            onInteraction: widget.onInteraction,
          ),
        if (peers > 0)
          _LinkedVolumeControl(
            groups: groups,
            layout: layout,
            onInteraction: widget.onInteraction,
            onDragging: widget.onDragging,
          ),
        if (widget.offset && peers > 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: layout.inner,
            children: [
              _LinkedOffsetControl(
                groups: groups,
                layout: layout,
                onInteraction: widget.onInteraction,
                onDragging: widget.onDragging,
              ),
              _LinkedOffsetButtons(
                groups: groups,
                layout: layout,
                onInteraction: widget.onInteraction,
              ),
            ],
          ),
        if (widget.sync && linkable) _LinkedSyncSwitch(width: groups.sync),
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
  const _LinkedSyncSwitch({required this.width});

  final double width;

  /// 开关旁的文字；在 Obx 中调用
  static String get label =>
      linkedPlayback.syncOn.value && !linkedPlayback.isConnected
      ? '未连接'
      : '同步';

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
            width: width,
            height: _Size.height,
            child: Row(
              spacing: _Size.switchGap,
              children: [
                Opacity(
                  opacity: on && !connected ? 0.5 : 1,
                  child: SizedBox(
                    width: _Size.switchWidth,
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
                    child: Text(label, maxLines: 1, style: _textStyle),
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

/// 文字按钮，文字两侧为点击边距 [padding]，宽度为文字与边距之和
Widget _textButton(
  String text,
  VoidCallback onTap, {
  EdgeInsets padding = const EdgeInsets.symmetric(
    horizontal: _Size.textInset,
  ),
  required _Metrics metrics,
  bool enabled = true,
}) => GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTap: onTap,
  child: SizedBox(
    width: metrics.measure(text, _dimTextStyle) + padding.horizontal,
    height: _Size.height,
    child: Padding(
      padding: padding,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          maxLines: 1,
          style: enabled
              ? _dimTextStyle
              : _dimTextStyle.copyWith(color: Colors.white38),
        ),
      ),
    ),
  ),
);

/// 宽为 [width] 的单行文本，放不下时缩小
Widget _label(
  double width,
  String text,
  TextStyle style, {
  Alignment alignment = Alignment.center,
}) => SizedBox(
  width: width,
  child: FittedBox(
    fit: BoxFit.scaleDown,
    alignment: alignment,
    child: Text(text, maxLines: 1, style: style),
  ),
);

/// 延迟偏移：两端标注快慢的横向拨轮（每格 0.5ms）与当前值
class _LinkedOffsetControl extends StatelessWidget {
  const _LinkedOffsetControl({
    required this.groups,
    required this.layout,
    required this.onInteraction,
    required this.onDragging,
  });

  final _Groups groups;
  final _Layout layout;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onDragging;

  @override
  Widget build(BuildContext context) {
    final metrics = groups.metrics;
    final short = layout.short;
    return SizedBox(
      width: groups.offset(layout),
      height: _Size.height,
      child: Row(
        spacing: layout.inner,
        children: [
          _label(
            metrics.slower(short),
            short ? linkedSlowerShortLabel : linkedSlowerLabel,
            _dimTextStyle,
          ),
          LinkedOffsetDial(
            axis: Axis.horizontal,
            length: layout.dial,
            thickness: 26,
            onInteraction: onInteraction,
            onDragging: onDragging,
          ),
          _label(
            metrics.faster(short),
            short ? linkedFasterShortLabel : linkedFasterLabel,
            _dimTextStyle,
          ),
          Obx(
            () => _label(
              metrics.offsetValue,
              formatLinkedOffset(linkedPlayback.currentOffsetUs ?? 0),
              _textStyle,
              // 预留最宽的值，较短的值靠右贴近归零
              alignment: Alignment.centerRight,
            ),
          ),
        ],
      ),
    );
  }
}

/// 偏移的归零，主控另有校准
class _LinkedOffsetButtons extends StatelessWidget {
  const _LinkedOffsetButtons({
    required this.groups,
    required this.layout,
    required this.onInteraction,
  });

  final _Groups groups;
  final _Layout layout;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    // 相邻的一侧各以组内间距的一半为点击边距
    final half = layout.inner / 2;
    return SizedBox(
      width: groups.buttons(layout),
      height: _Size.height,
      child: Row(
        children: [
          _textButton(
            _zeroLabel,
            () {
              onInteraction();
              linkedPlayback.setOffset(0);
            },
            padding: EdgeInsets.only(
              left: _Size.textInset,
              right: groups.calibrate ? half : _Size.textInset,
            ),
            metrics: groups.metrics,
          ),
          if (groups.calibrate)
            _LinkedCalibrateButton(
              metrics: groups.metrics,
              padding: EdgeInsets.only(left: half, right: _Size.textInset),
              onInteraction: onInteraction,
            ),
        ],
      ),
    );
  }
}

/// 主控的校准按钮：打开校准面板（按频段对齐、开始校准；暂时不能校准时面板中
/// 说明原因），点击由按钮接住，不会落到播放器上
class _LinkedCalibrateButton extends StatelessWidget {
  const _LinkedCalibrateButton({
    required this.metrics,
    this.padding = const EdgeInsets.symmetric(horizontal: _Size.textInset),
    required this.onInteraction,
  });

  final _Metrics metrics;

  /// 文字两侧的点击边距
  final EdgeInsets padding;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '声学校准与按频段对齐',
      child: _textButton(
        _calibrateLabel,
        () {
          onInteraction();
          openLinkedCalibration();
        },
        padding: padding,
        metrics: metrics,
      ),
    );
  }
}

/// 主控当前调节的跟随端（偏移与音量共用）：名称前总有切换图标，只有一台时置灰
/// 不可切换，多台时点击依次切换；名称过长时省略，悬停或长按查看完整名称
class _LinkedPeerChip extends StatelessWidget {
  const _LinkedPeerChip({required this.width, required this.onInteraction});

  final double width;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final peers = linkedPlayback.adjustablePeers;
      final peer = linkedPlayback.selectedPeer;
      final multiple = peers.length > 1;
      return Tooltip(
        message: peer == null
            ? ''
            : multiple
            ? '${peer.name}（点击切换跟随端）'
            : peer.name,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            onInteraction();
            if (!multiple || peer == null) return;
            final index = peers.indexWhere((e) => e.id == peer.id);
            linkedPlayback.selectPeer(peers[(index + 1) % peers.length].id);
          },
          child: SizedBox(
            width: width,
            height: _Size.height,
            child: Row(
              spacing: _Size.iconGap,
              children: [
                Icon(
                  Icons.swap_horiz_rounded,
                  size: _Size.icon,
                  color: multiple ? Colors.white : Colors.white38,
                ),
                Expanded(
                  child: Text(
                    peer?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _textStyle,
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

/// 跟随端音量：模式切换（跟随主控 / 独立）、当前值与竖向拨轮（上拖变大）；
/// 主控端调节当前的跟随端
class _LinkedVolumeControl extends StatefulWidget {
  const _LinkedVolumeControl({
    required this.groups,
    required this.layout,
    required this.onInteraction,
    required this.onDragging,
  });

  final _Groups groups;
  final _Layout layout;
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
                      horizontal: _Size.modePadding,
                    ),
                    child: Center(
                      child: Text(
                        widget.layout.short ? mode.shortLabel : mode.label,
                        maxLines: 1,
                        style: mode == volume.mode
                            ? _textStyle
                            : _dimValueStyle,
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

  /// 当前值与拨轮
  List<Widget> _adjust(
    String? id,
    LinkedVolume volume,
    ValueChanged<LinkedVolume> onChanged,
  ) {
    final leader = linkedPlayback.leaderVolume.value;
    final follow = volume.mode == LinkedVolumeMode.follow;
    // 拨轮按调节的目标逐格滚动；主控音量未知时只能按偏移
    final target = volume.targetFor(leader);
    final index = target == null ? volume.offset : (target * 100).round();
    // 跟随主控时显示设备回报的实际音量（系统音量有档位，与目标可能不同），
    // 主控音量未知时显示偏移
    final shown = !follow
        ? volume.level
        : leader == null
        ? null
        : volume.actual ?? target;
    return [
      _label(
        widget.groups.metrics.volumeValue,
        shown == null ? _signed(volume.offset) : '${(shown * 100).round()}%',
        _textStyle,
        alignment: Alignment.centerRight,
      ),
      LinkedDial(
        key: ValueKey<String?>(id),
        index: index,
        axis: Axis.vertical,
        length: _Size.height,
        thickness: _Size.volumeDial,
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
            // 主控音量已知时偏移只在生效音量 0~100% 内调节：先把超出范围的
            // 偏移收回范围内再调节，每格都有变化
            final percent = leader == null ? 0 : (leader * 100).round();
            final low = leader == null ? -100 : math.max(-100, -percent);
            final high = leader == null ? 100 : math.min(100, 100 - percent);
            next = base.copyWith(
              offset: (base.offset.clamp(low, high) + steps).clamp(low, high),
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
    ];
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
        if (peer == null) {
          return SizedBox(width: widget.groups.volume(widget.layout));
        }
        final selectedId = id = peer.id;
        volume = peer.volume!;
        onChanged = (value) => linkedPlayback.setVolume(selectedId, value);
      }
      return SizedBox(
        width: widget.groups.volume(widget.layout),
        height: _Size.height,
        child: Row(
          spacing: widget.layout.inner,
          children: [
            const Icon(
              Icons.volume_up_outlined,
              size: _Size.icon,
              color: Colors.white,
            ),
            // 字体放大时整体缩小到底栏高度内
            SizedBox(
              width: widget.groups.metrics.toggle(widget.layout.short),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _modeToggle(volume, onChanged),
              ),
            ),
            ..._adjust(id, volume, onChanged),
          ],
        ),
      );
    });
  }
}
