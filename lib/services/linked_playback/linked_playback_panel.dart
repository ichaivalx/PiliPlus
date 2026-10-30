import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/services/linked_playback/linked_playback.dart';
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

/// 联动播放的开关、角色、连接状态，主控另有跟随端的延迟偏移
class LinkedPlaybackPanel extends StatelessWidget {
  const LinkedPlaybackPanel({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  static const _offsetRange = 500;
  static const _offsetSteps = [-10, -1, 1, 10];

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
            subtitle: const Text('同一 WiFi 下，跟随端自动打开并同步播放主控正在播放的普通视频'),
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
          else if (enabled)
            ...switch (role) {
              LinkedRole.leader => _leaderStatus(),
              LinkedRole.follower => _followerStatus(),
            },
        ],
      );
    });
  }

  List<Widget> _leaderStatus() {
    final peers = linkedPlayback.peers;
    final offset = linkedPlayback.offsetMs.value;
    return [
      ListTile(
        title: Text(
          peers.isEmpty ? '等待跟随端连接' : '已连接 ${peers.length} 台跟随端',
        ),
        subtitle: peers.isEmpty
            ? const Text('跟随端开启联动播放并选择「跟随」，打开应用后自动连接')
            : null,
      ),
      for (final peer in peers)
        ListTile(
          dense: true,
          title: Text(peer.address),
          subtitle: Text(
            '偏差 ${_signedMs(peer.driftMs)}　往返 ${_ms(peer.rttMs)}',
          ),
        ),
      ListTile(
        title: Text('跟随端延迟偏移 $offset ms'),
        subtitle: const Text('跟随端声音偏早时调大，偏晚时调小；偏差为正表示跟随端超前'),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Slider(
          min: -_offsetRange.toDouble(),
          max: _offsetRange.toDouble(),
          divisions: _offsetRange * 2,
          value: offset.clamp(-_offsetRange, _offsetRange).toDouble(),
          label: '$offset ms',
          onChanged: (value) => linkedPlayback.setOffset(value.round()),
        ),
      ),
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          for (final step in _offsetSteps)
            TextButton(
              onPressed: () => linkedPlayback.setOffset(offset + step),
              child: Text(step > 0 ? '+$step' : '$step'),
            ),
          TextButton(
            onPressed: () => linkedPlayback.setOffset(0),
            child: const Text('归零'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _followerStatus() {
    final leader = linkedPlayback.leader.value;
    return [
      ListTile(
        title: Text(leader == null ? '正在查找主控' : '已连接主控 $leader'),
        subtitle: Text(
          leader == null
              ? '需与主控连接同一 WiFi，主控开启联动播放并选择「主控」'
              : '偏差 ${_signedMs(linkedPlayback.driftMs.value)}'
                    '　往返 ${_ms(linkedPlayback.rttMs.value)}',
        ),
      ),
    ];
  }
}
