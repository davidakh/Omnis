# Packages

- `mlx-swift-lm` — ml-explore/mlx-swift-lm 3.32.3, vendored so it can depend on
  PrismML-Eng/mlx-swift (`prism` branch), which adds the 1-bit / ternary kernels the
  Bonsai models need. The only change is the `mlx-swift` dependency in `Package.swift`.
