import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
import 'package:PiliPlus/services/linked_playback/offset_dial.dart';
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

/// 联动播放的开关、角色、同步、连接状态与延迟偏移；主控另有跟随端的状态与音量
class LinkedPlaybackPanel extends StatelessWidget {
  const LinkedPlaybackPanel({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  /// 步进按钮（毫秒）
  static const _offsetSteps = [-10, 10];

  static String _signedMs(double? value) => value == null
      ? '—'
      : '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} ms';

  static String _ms(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)} ms';

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
            subtitle: const Text(
              '同一 WiFi 下，跟随端自动打开并同步播放主控正在播放的普通视频；开启期间常驻通知以保持熄屏后的连接',
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
              LinkedRole.leader => _leaderStatus(theme),
              LinkedRole.follower => _followerStatus(),
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
            ? const Text('跟随端开启联动播放并选择「跟随」，打开应用后自动连接')
            : null,
      ),
      for (final peer in peers) ..._peer(theme, peer),
    ];
  }

  List<Widget> _offset(ThemeData theme) {
    final offset = linkedPlayback.offsetUs.value;
    return [
      ListTile(
        title: Text('跟随端延迟偏移 ${formatLinkedOffset(offset)}'),
        subtitle: const Text(
          '左右拖动拨轮，每格 0.5 ms；跟随端声音偏早时调大，偏晚时调小。两端共用，偏差为正表示跟随端超前',
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
              onPressed: () => linkedPlayback.setOffset(offset + step * 1000),
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
            ],
          ),
        ),
      ),
      if (!offline && volume != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.volume_up_outlined, size: 20),
              ),
              Expanded(
                child: Slider(
                  value: volume.clamp(0.0, 1.0).toDouble(),
                  divisions: 100,
                  label: '${(volume * 100).round()}%',
                  onChanged: (value) =>
                      linkedPlayback.setPeerVolume(peer.id, value),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _followerStatus() {
    final leader = linkedPlayback.leader.value;
    return [
      ListTile(
        onTap: leader == null ? linkedPlayback.wake : null,
        title: Text(leader == null ? '正在查找主控' : '已连接主控 $leader'),
        subtitle: Text(
          leader == null
              ? '需与主控连接同一 WiFi，主控开启联动播放并选择「主控」；点击立即重试'
              : '偏差 ${_signedMs(linkedPlayback.driftMs.value)}'
                    '　往返 ${_ms(linkedPlayback.rttMs.value)}',
        ),
      ),
    ];
  }
}
