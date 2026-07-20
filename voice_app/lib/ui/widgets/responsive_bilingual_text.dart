import 'package:flutter/material.dart';

/// Shows [english] only on narrow layouts; adds ([chinese]) when there is room.
class ResponsiveBilingualText extends StatelessWidget {
  const ResponsiveBilingualText({
    super.key,
    required this.english,
    required this.chinese,
    this.style,
    this.textAlign,
    this.compactWidthThreshold = 320,
  });

  final String english;
  final String chinese;
  final TextStyle? style;
  final TextAlign? textAlign;
  final double compactWidthThreshold;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = !width.isFinite || width < compactWidthThreshold;
        return Text(
          compact ? english : '$english ($chinese)',
          style: style,
          textAlign: textAlign,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        );
      },
    );
  }
}
