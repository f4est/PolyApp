import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 56,
    this.animated = false,
    this.semanticLabel = 'PolyApp logo',
  });

  final double size;
  final bool animated;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final logo = animated
        ? Image.asset(
            'assets/branding/logo_anim.gif',
            width: size,
            height: size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          )
        : SvgPicture.asset(
            'assets/branding/logo.svg',
            width: size,
            height: size,
            fit: BoxFit.contain,
            semanticsLabel: semanticLabel,
          );
    return ExcludeSemantics(excluding: false, child: logo);
  }
}

class BrandLoadingIndicator extends StatelessWidget {
  const BrandLoadingIndicator({
    super.key,
    this.label,
    this.dark = false,
    this.logoSize = 72,
    this.spacing = 12,
  });

  final String? label;
  final bool dark;
  final double logoSize;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : const Color(0xFF0F172A);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandLogo(size: logoSize, animated: true),
        SizedBox(height: spacing),
        SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
        ),
        if (label != null && label!.trim().isNotEmpty) ...[
          SizedBox(height: spacing - 2),
          Text(
            label!,
            style: TextStyle(color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}
