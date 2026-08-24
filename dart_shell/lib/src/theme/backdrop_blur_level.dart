enum ShellBackdropBlurLevel {
  shitty(sigma: 6, downsampleScale: 0.25),
  fast(sigma: 6, downsampleScale: 0.5),
  good(sigma: 6, downsampleScale: 1),
  best(sigma: 14, downsampleScale: 1);

  const ShellBackdropBlurLevel({
    required this.sigma,
    required this.downsampleScale,
  });

  final double sigma;
  final double downsampleScale;
}
