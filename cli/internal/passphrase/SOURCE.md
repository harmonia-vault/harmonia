# 常见口令表的来源

`common-passwords.txt` 用于在设置、修改管理口令时拒绝常见口令（设计文档 16.4）。它编译进程序，运行时不联网获取或更新。

- 来源：[danielmiessler/SecLists](https://github.com/danielmiessler/SecLists) 的 `Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt`
- 提交：`3a5f62f0e18a1b8a36b25399aff0077f3706e5af`
- 原文件 SHA-256：`c2e5696882c603b76bb67a47ee970897e5a76fc4c3f5547abe3d0ca340c576e0`
- 许可证：MIT，全文见 `LICENSE-SecLists`

处理方式：只保留 8–128 个可见 ASCII 字符的条目；去掉不含字母、且只有数字或只有符号的条目（它们怎么改大小写都过不了“四类中至少两类”）；转成小写、去重、排序。共 37,736 条。

更新这张表只能替换这里的文件并随新版本发布。口令规则和这张表只在设置、修改口令时检查，解锁时不检查，所以更新不会让已经设置的口令失效。
