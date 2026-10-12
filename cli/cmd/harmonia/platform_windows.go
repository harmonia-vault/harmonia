package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"

	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/sysenv"
)

// notFoundHint 是找不到要运行的命令时补充的说明。
const notFoundHint = "。如果它是 cmd 或 PowerShell 自带的命令，请写成 cmd /c <命令> 或 powershell -Command <命令>"

// replaceProcess 运行命令并以它的退出码结束。Windows 不能替换当前进程，只能等它运行完；
// Ctrl+C 由控制台同时发给它和本进程，本进程不处理，由它决定是否退出。
func replaceProcess(bin string, args, env []string) error {
	cmd := exec.Command(bin, args[1:]...)
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		os.Exit(exit.ExitCode())
	}
	if err != nil {
		return err
	}
	os.Exit(0)
	return nil
}

// background 为后台服务做准备：--home 指定数据目录（计划任务不能设置环境变量），
// 登记“正在运行”，并在 CLI 要求停止时结束。同一个数据目录已有后台服务时返回错误。
func background(ctx context.Context, args []string) (context.Context, func(), error) {
	f, err := parseFlags(args, "home")
	if err != nil {
		return nil, nil, err
	}
	if home := f.values["home"]; home != "" {
		os.Setenv("HARMONIA_HOME", home)
	}
	d, err := state.Open()
	if err != nil {
		return nil, nil, err
	}
	stop, release, err := service.Hold(d.Path)
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	go func() {
		select {
		case <-stop:
			cancel()
		case <-ctx.Done():
		}
	}()
	return ctx, func() { cancel(); release() }, nil
}

// newProgramName 是升级时新版本的临时文件名，与 harmonia.exe 放在同一个目录。
const newProgramName = "harmonia-new.exe"

// swapProgram 换上新版本。运行中的程序不能被覆盖或删除，但可以改名：
// 先把当前程序改名为 .old，再把新版本放到原来的位置。
func swapProgram(tmp, bin string) error {
	old := bin + ".old"
	stale, _ := filepath.Glob(old + ".*")
	for _, p := range stale {
		_ = os.Remove(p)
	}
	if err := os.Remove(old); err != nil && !errors.Is(err, os.ErrNotExist) {
		// 上一个旧版本还有进程在运行（例如 harmonia exec 启动的程序还没结束），给它换个名字让出位置。
		if err := os.Rename(old, fmt.Sprintf("%s.%d", old, time.Now().Unix())); err != nil {
			return err
		}
	}
	if err := os.Rename(bin, old); err != nil {
		return err
	}
	if err := os.Rename(tmp, bin); err != nil {
		_ = os.Rename(old, bin)
		return err
	}
	return nil
}

// removeProgram 在卸载时删除 harmonia.exe 和保留的旧版本。程序装在默认位置时，
// 同时把安装目录从用户的 Path 中去掉并删除这个目录。运行中的程序不能删除自身，
// 所以交给一个稍后执行的系统命令：等本进程退出后再删。
func removeProgram(bin string) {
	dir := filepath.Dir(bin)
	script := fmt.Sprintf(`ping -n 3 127.0.0.1 >nul & del /f /q "%s" "%s.old" "%s.old.*"`, bin, bin, bin)
	if strings.EqualFold(dir, defaultInstallDir()) {
		_ = sysenv.RemoveFromPath(dir)
		script += fmt.Sprintf(` & rmdir "%s"`, dir)
	}
	cmd := exec.Command(os.Getenv("ComSpec"))
	cmd.Dir = os.TempDir()
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CmdLine:       fmt.Sprintf(`cmd.exe /d /s /c "%s"`, script),
		HideWindow:    true,
		CreationFlags: windows.CREATE_NO_WINDOW | windows.CREATE_NEW_PROCESS_GROUP,
	}
	_ = cmd.Start()
}

// defaultInstallDir 是安装脚本放置 harmonia.exe 的目录。
func defaultInstallDir() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "Harmonia")
}
