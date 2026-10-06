// 本机存储接口：App 用安全存储与应用私有文件实现，测试与命令行工具用内存或文件实现。
import 'dart:io';

abstract class LocalStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryStore implements LocalStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 把每个键存成目录下的一个文件（原子替换）。
class FileStore implements LocalStore {
  FileStore(this.dir);
  final Directory dir;

  File _file(String key) => File('${dir.path}/$key.json');

  @override
  Future<String?> read(String key) async {
    final f = _file(key);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/.$key.tmp');
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(_file(key).path);
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }
}
