package main

import "context"

// Windows 的用户环境变量功能随程序提供，无需准备终端加载入口。
func ensureShellIntegration() error                     { return nil }
func prepareUpdatedShell(context.Context, string) error { return nil }
