import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/linked_playback/offset_dial.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 设置中的联动播放页
class LinkedPlaybackPage extends StatelessWidget {
  const LinkedPlaybackPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('联动播放')),
      body: const ViewSafeArea(child: LinkedPlaybackPanel()),
    );
  }
}

/// 联动播放的开关、角色、同步、连接状态、跟随端音量与延迟偏移
class LinkedPlaybackPanel extends StatelessWidget {
  const LinkedPlaybackPanel({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  /// 步进按钮（毫秒）
  static const _offsetSteps = [-10, 10];

  /// 跟随端选择项的标签宽度扣除的选择项内边距与边框
  static const _peerChipInset = 48.0;

  static String _signedMs(double? value) => value == null
      ? '—'
      : '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} ms';

  static String _ms(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)} ms';

  /// 桌面端未连接时的提示：防火墙未放行时其他设备找不到本机
  static final String _desktopHint = PlatformUtils.isDesktop
      ? '\n若一直无法连接：确认本机当前网络为「专用网络」，并在系统防火墙中允许'
            ' PiliPlus 通过专用网络（首次开启时弹出的防火墙提示请选择允许）'
      : '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final enabled = linkedPlayback.enabled.value;
      final role = linkedPlayback.role.value;
      final error = linkedPlayback.error.value;
      return ListView(
        padding: padding,
        children: [
          ListTile(
            onTap: () => linkedPlayback.setEnabled(!enabled),
            title: const Text('联动播放'),
            subtitle: Text(
              PlatformUtils.isDesktop
                  ? '同一局域网下，跟随端自动打开并同步播放主控正在播放的普通视频；桌面端调节的是本机播放器音量'
                  : '同一 WiFi 下，跟随端自动打开并同步播放主控正在播放的普通视频；开启期间常驻通知以保持熄屏后的连接',
            ),
            trailing: Switch(
              value: enabled,
              onChanged: linkedPlayback.setEnabled,
            ),
          ),
          ListTile(
            title: const Text('本机角色'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                for (final item in LinkedRole.values)
                  ActionRowLineItem(
                    selectStatus: item == role,
                    text: item.label,
                    onTap: () => linkedPlayback.setRole(item),
                  ),
              ],
            ),
          ),
          if (error != null)
            ListTile(
              title: Text(
                error,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          else if (enabled) ...[
            ListTile(
              onTap: () => linkedPlayback
                ..toggleSync()
                ..wake(),
              title: const Text('同步播放'),
              subtitle: const Text('两端共用此开关；关闭后保持连接，跟随端暂停，主控单独播放'),
              trailing: Switch(
                value: linkedPlayback.syncOn.value,
                onChanged: (_) => linkedPlayback
                  ..toggleSync()
                  ..wake(),
              ),
            ),
            ...switch (role) {
              LinkedRole.leader => [
                ..._seekMode(),
                ..._leaderStatus(theme),
              ],
              LinkedRole.follower => _followerStatus(theme),
            },
            ..._offset(theme),
          ],
        ],
      );
    });
  }

  List<Widget> _leaderStatus(ThemeData theme) {
    final peers = linkedPlayback.peers;
    final online = peers.where((e) => e.state != LinkedPeerState.offline);
    return [
      ListTile(
        title: Text(
          online.isEmpty ? '等待跟随端连接' : '已连接 ${online.length} 台跟随端',
        ),
        subtitle: peers.isEmpty
            ? Text('跟随端开启联动播放并选择「跟随」，打开应用后自动连接$_desktopHint')
            : null,
      ),
      for (final peer in peers) ..._peer(theme, peer),
    ];
  }

  /// 拖动进度时的同步方式，由主控决定
  List<Widget> _seekMode() {
    final mode = linkedPlayback.seekMode.value;
    return [
      ListTile(
        title: const Text('拖动进度时的同步方式'),
        subtitle: Text(mode.description),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            for (final item in LinkedSeekMode.values)
              ActionRowLineItem(
                selectStatus: item == mode,
                text: item.label,
                onTap: () => linkedPlayback.setSeekMode(item),
              ),
          ],
        ),
      ),
    ];
  }

  static String _percent(double? value) =>
      value == null ? '—' : '${(value * 100).round()}%';

  /// 跟随端的音量模式、偏移或音量，及当前实际音量
  List<Widget> _volume(
    ThemeData theme,
    LinkedVolume volume,
    ValueChanged<LinkedVolume> onChanged,
  ) {
    final leaderVolume = linkedPlayback.leaderVolume.value;
    final follow = volume.mode == LinkedVolumeMode.follow;
    final offset = volume.offset;
    return [
      ListTile(
        dense: true,
        leading: const Icon(Icons.volume_up_outlined, size: 20),
        title: Text(
          follow
              ? '主控 ${_percent(leaderVolume)}　偏移 ${offset > 0 ? '+' : ''}$offset'
              : '设定 ${_percent(volume.level)}',
        ),
        subtitle: Text('跟随端当前音量 ${_percent(volume.actual)}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (final item in LinkedVolumeMode.values)
              ActionRowLineItem(
                selectStatus: item == volume.mode,
                text: item.label,
                onTap: () {
                  if (item != volume.mode) {
                    onChanged(volume.switchTo(item, leaderVolume));
                  }
                },
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: follow
            ? Slider(
                min: -100,
                max: 100,
                divisions: 200,
                value: offset.clamp(-100, 100).toDouble(),
                label: '${offset > 0 ? '+' : ''}$offset',
                onChanged: (value) =>
                    onChanged(volume.copyWith(offset: value.round())),
              )
            : Slider(
                divisions: 100,
                value: volume.level.clamp(0.0, 1.0).toDouble(),
                label: _percent(volume.level),
                onChanged: (value) => onChanged(volume.copyWith(level: value)),
              ),
      ),
    ];
  }

  /// 延迟偏移：跟随端调节本机的，主控调节当前跟随端的（与底栏共用所选的跟随端）
  List<Widget> _offset(ThemeData theme) {
    final follower = linkedPlayback.role.value == LinkedRole.follower;
    final peers = follower
        ? const <LinkedPeerInfo>[]
        : linkedPlayback.adjustablePeers;
    final peer = follower ? null : linkedPlayback.selectedPeer;
    if (!follower && peer == null) return const [];
    final offset = linkedPlayback.currentOffsetUs ?? 0;
    return [
      ListTile(
        title: Text(
          follower
              ? '本机延迟偏移 ${formatLinkedOffset(offset)}'
              : '${peer!.name} 的延迟偏移 ${formatLinkedOffset(offset)}',
        ),
        subtitle: Text(
          follower
              ? '左右拖动拨轮，每格 0.5 ms；本机声音偏早时调大，偏晚时调小。各跟随端分别设置，偏差为正表示本机超前'
              : '左右拖动拨轮，每格 0.5 ms；该跟随端声音偏早时调大，偏晚时调小。各跟随端分别设置，偏差为正表示跟随端超前',
        ),
      ),
      // 名称过长时省略，悬停或长按查看完整名称
      if (peers.length > 1)
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final item in peers)
                  ChoiceChip(
                    tooltip: item.name,
                    showCheckmark: false,
                    selected: item.id == peer!.id,
                    onSelected: (_) => linkedPlayback.selectPeer(item.id),
                    label: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(
                          0.0,
                          constraints.maxWidth - _peerChipInset,
                        ),
                      ),
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LayoutBuilder(
          builder: (context, constraints) => DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            child: LinkedOffsetDial(
              axis: Axis.horizontal,
              length: constraints.maxWidth,
              thickness: 48,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          for (final step in _offsetSteps)
            TextButton(
              onPressed: () => linkedPlayback.adjustOffset(step * 1000),
              child: Text(step > 0 ? '+$step ms' : '$step ms'),
            ),
          TextButton(
            onPressed: () => linkedPlayback.setOffset(0),
            child: const Text('归零'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _peer(ThemeData theme, LinkedPeerInfo peer) {
    final offline = peer.state == LinkedPeerState.offline;
    final failed = peer.state == LinkedPeerState.failed;
    final volume = peer.volume;
    return [
      ListTile(
        dense: true,
        title: Text('${peer.name}（${peer.address}）'),
        subtitle: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: failed && peer.reason != null
                    ? '${peer.state.label}：${peer.reason}'
                    : peer.state.label,
                style: failed || offline
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
              if (!offline)
                TextSpan(
                  text:
                      '　偏差 ${_signedMs(peer.driftMs)}　往返 ${_ms(peer.rttMs)}',
                ),
              if (peer.offsetUs case final offset? when !offline)
                TextSpan(text: '　延迟偏移 ${formatLinkedOffset(offset)}'),
            ],
          ),
        ),
      ),
      if (!offline && volume != null)
        ..._volume(
          theme,
          volume,
          (value) => linkedPlayback.setVolume(peer.id, value),
        ),
    ];
  }

  List<Widget> _followerStatus(ThemeData theme) {
    final leader = linkedPlayback.leader.value;
    return [
      ListTile(
        onTap: leader == null ? linkedPlayback.wake : null,
        title: Text(leader == null ? '正在查找主控' : '已连接主控 $leader'),
        subtitle: Text(
          leader == null
              ? '需与主控连接同一局域网，主控开启联动播放并选择「主控」；点击立即重试$_desktopHint'
              : '偏差 ${_signedMs(linkedPlayback.driftMs.value)}'
                    '　往返 ${_ms(linkedPlayback.rttMs.value)}',
        ),
      ),
      ..._volume(
        theme,
        linkedPlayback.volume.value,
        (value) => linkedPlayback.setVolume(null, value),
      ),
    ];
  }
}
