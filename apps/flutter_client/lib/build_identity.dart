abstract final class BuildIdentity {
  static const productVersion = String.fromEnvironment('READARC_BUILD_NAME', defaultValue: '0.49.1');

  /// Cross-platform CI identity shown to users. Android's package versionCode
  /// may use a compatibility offset, but this value remains the same on every
  /// artifact produced by one verified workflow run.
  static const buildNumber = String.fromEnvironment('READARC_BUILD_NUMBER', defaultValue: '42');

  static const display = '$productVersion ($buildNumber)';
}
