import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';

void main() {
  test('a connection URI reads as the database editor\'s fields', () {
    expect(
      parseDbUri(
        'postgresql://ann:s%40cret@db.internal:6543/shop?sslmode=require',
      ),
      (
        kind: DbKind.postgres,
        address: 'db.internal',
        port: 6543,
        user: 'ann',
        password: 's@cret',
        database: 'shop',
      ),
    );
    // No host is PostgreSQL's own socket, so the host itself.
    expect(parseDbUri(' postgres:///shop '), (
      kind: DbKind.postgres,
      address: 'localhost',
      port: 5432,
      user: '',
      password: null,
      database: 'shop',
    ));
    // authSource over the path, and a replica set's first member.
    expect(
      parseDbUri(
        'mongodb://root:p%2Cw@m1:27018,m2:27019/app'
        '?authSource=admin&replicaSet=rs0',
      ),
      (
        kind: DbKind.mongo,
        address: 'm1',
        port: 27018,
        user: 'root',
        password: 'p,w',
        database: 'admin',
      ),
    );
    expect(parseDbUri('mongodb://m1/app'), (
      kind: DbKind.mongo,
      address: 'm1',
      port: 27017,
      user: '',
      password: null,
      database: 'app',
    ));
    expect(parseDbUri('redis://:hunter2@[::1]:6380/3'), (
      kind: DbKind.redis,
      address: '::1',
      port: 6380,
      user: '',
      password: 'hunter2',
      database: '3',
    ));
    for (final refused in [
      'mongodb+srv://cluster.example/app',
      'rediss://cache.example',
      'mysql://db.example/shop',
      'nonsense',
    ]) {
      expect(() => parseDbUri(refused), throwsFormatException, reason: refused);
    }
  });
}
