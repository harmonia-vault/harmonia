package main

// 输出信息类命令保持只读；shell install 自己处理准备与手动配置提示。
func preparesShell(args []string) bool {
	switch args[0] {
	case "version", "help", "skill", "logout", "uninstall", "shell":
		return false
	default:
		return true
	}
}
