import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// 预先下载并解码图片，之后显示时直接命中图片缓存；[url] 与解码尺寸需与
/// 显示时的 `CachedNetworkImage` 一致
void precacheNetworkImage(
  BuildContext context,
  String url, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  precacheImage(
    ResizeImage.resizeIfNeeded(
      cacheWidth,
      cacheHeight,
      CachedNetworkImageProvider(url, cacheKey: url),
    ),
    context,
    onError: (_, _) {},
  );
}

/// 按 `NetworkImgLayer` 的图片地址与解码尺寸预先缓存
void precacheNetworkImg(
  BuildContext context,
  String? src, {
  required double width,
  required double height,
}) {
  if (src == null || src.isEmpty) {
    return;
  }
  final byWidth = width <= height;
  precacheNetworkImage(
    context,
    ImageUtils.thumbnailUrl(src),
    cacheWidth: byWidth ? width.cacheSize(context) : null,
    cacheHeight: byWidth ? null : height.cacheSize(context),
  );
}
