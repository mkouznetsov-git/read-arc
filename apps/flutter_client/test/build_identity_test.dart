import 'package:flutter_test/flutter_test.dart';
import 'package:readarc/build_identity.dart';

void main() {
  test('default build identity keeps product version separate from build number', () {
    expect(BuildIdentity.productVersion, '0.49.1');
    expect(BuildIdentity.buildNumber, matches(RegExp(r'^\d+$')));
    expect(BuildIdentity.display, '${BuildIdentity.productVersion} (${BuildIdentity.buildNumber})');
  });
}
