package main

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"time"
	"unicode/utf16"
)

func configureProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

func configureCancel(cmd *exec.Cmd) {
	cmd.Cancel = func() error {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		kill := exec.CommandContext(ctx, "taskkill.exe", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F")
		configureProcess(kill)
		if err := kill.Run(); err != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
	cmd.WaitDelay = 3 * time.Second
}

func desktop(origin, token string) error {
	script := utf16.Encode([]rune(windowsUI))
	bytes := make([]byte, len(script)*2)
	for i, value := range script {
		binary.LittleEndian.PutUint16(bytes[i*2:], value)
	}
	command := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-EncodedCommand", base64.StdEncoding.EncodeToString(bytes))
	command.Env = append(os.Environ(), "BILI_ORIGIN="+origin, "BILI_TOKEN="+token)
	configureProcess(command)
	return command.Run()
}

//go:embed windows.ps1
var windowsUI string
