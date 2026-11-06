package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

var formats = map[string][]string{
	"mp4": {"-f", "bv[vcodec^=avc]+ba[ext=m4a]/b[ext=mp4]/bv+ba/b", "--merge-output-format", "mp4", "--remux-video", "mp4"},
	"mp3": {"-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"},
	"m4a": {"-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"},
}

type taskState struct {
	Status string   `json:"status"`
	Log    []string `json:"log"`
	File   string   `json:"file"`
}

type app struct {
	mu                           sync.Mutex
	state                        taskState
	cancel                       context.CancelFunc
	tools, folder, origin, token string
}

var shareURL = regexp.MustCompile(`https?://[^\s<>"“”。，；、！）】]+`)
var bareID = regexp.MustCompile(`^(BV[a-zA-Z0-9]{10}|av[0-9]+)$`)

func videoURL(input string) (string, error) {
	input = strings.TrimSpace(input)
	if bareID.MatchString(input) {
		return "https://www.bilibili.com/video/" + input, nil
	}
	for _, candidate := range shareURL.FindAllString(input, -1) {
		u, err := url.Parse(candidate)
		if err != nil || u.User != nil || u.Port() != "" {
			continue
		}
		host := strings.ToLower(u.Hostname())
		if host == "b23.tv" || ((host == "www.bilibili.com" || host == "m.bilibili.com" || host == "bilibili.com") &&
			(strings.HasPrefix(u.Path, "/video/") || strings.HasPrefix(u.Path, "/bangumi/play/"))) {
			u.Scheme = "https"
			return u.String(), nil
		}
	}
	return "", errors.New("请输入 B 站视频链接、b23.tv 分享链接或 BV/av 号")
}

func exeName(name string) string {
	if runtime.GOOS == "windows" {
		return name + ".exe"
	}
	return name
}

func (a *app) appendLog(line string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.state.Log = append(a.state.Log, line)
	if len(a.state.Log) > 100 {
		a.state.Log = a.state.Log[1:]
	}
}

func (a *app) download(ctx context.Context, target, format, folder string) {
	filename := "%(title)s [%(id)s].%(ext)s"
	if format != "mp4" {
		filename = "%(title)s [%(id)s] [" + strings.ToUpper(format) + "].%(ext)s"
	}
	args := []string{"--ignore-config", "--no-playlist", "--newline", "--no-colors", "--progress",
		"--encoding", "utf-8", "--windows-filenames", "--trim-filenames", "130", "--no-overwrites",
		"--ffmpeg-location", a.tools, "-P", folder, "-o", filename,
		"--no-simulate", "--print", "after_move:FINAL:%(filepath)s"}
	args = append(args, formats[format]...)
	args = append(args, "--", target)
	cmd := exec.CommandContext(ctx, filepath.Join(a.tools, exeName("yt-dlp")), args...)
	configureProcess(cmd)
	configureCancel(cmd)
	cmd.Dir = folder
	pipe, err := cmd.StdoutPipe()
	if err == nil {
		cmd.Stderr = cmd.Stdout
		err = cmd.Start()
	}
	var file string
	if err == nil {
		scan := bufio.NewScanner(pipe)
		scan.Buffer(make([]byte, 4096), 1024*1024)
		for scan.Scan() {
			line := scan.Text()
			if strings.HasPrefix(line, "FINAL:") {
				file = strings.TrimPrefix(line, "FINAL:")
			} else {
				a.appendLog(line)
			}
		}
		if scan.Err() != nil {
			_ = cmd.Process.Kill()
		}
		err = cmd.Wait()
		if err == nil {
			err = scan.Err()
		}
	}
	if err == nil {
		if info, statErr := os.Stat(file); statErr != nil || !info.Mode().IsRegular() || info.Size() == 0 || !strings.EqualFold(filepath.Ext(file), "."+format) {
			err = errors.New("未找到有效的输出文件")
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	switch {
	case ctx.Err() != nil:
		a.state.Status = "已取消"
	case err != nil:
		a.state.Status = "下载失败"
		a.state.Log = append(a.state.Log, err.Error())
	default:
		a.state.Status = "已完成"
		a.state.File = file
	}
	a.cancel()
	a.cancel = nil
}

func launch(target string) error {
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.Command("explorer.exe", target)
	} else {
		cmd = exec.Command("open", target)
	}
	configureProcess(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/state", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(struct {
			taskState
			Folder string `json:"folder"`
		}{a.state, a.folder})
	})
	mux.HandleFunc("POST /api/start", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ URL, Format, Folder string }
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16384)).Decode(&req); err != nil {
			http.Error(w, "无法读取任务参数", 400)
			return
		}
		target, err := videoURL(req.URL)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if _, ok := formats[req.Format]; !ok {
			http.Error(w, "请选择输出格式", 400)
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.cancel != nil {
			http.Error(w, "已有任务正在运行", 409)
			return
		}
		folder := strings.TrimSpace(req.Folder)
		if folder == "" {
			folder = a.folder
		}
		if !filepath.IsAbs(folder) {
			http.Error(w, "请输入保存目录的完整路径", 400)
			return
		}
		folder = filepath.Clean(folder)
		if err := os.MkdirAll(folder, 0755); err != nil {
			http.Error(w, "无法创建保存目录："+err.Error(), 400)
			return
		}
		for _, tool := range []string{"yt-dlp", "ffmpeg", "ffprobe"} {
			if _, err := os.Stat(filepath.Join(a.tools, exeName(tool))); err != nil {
				http.Error(w, "缺少 "+tool+"，请完整解压应用包", 500)
				return
			}
		}
		ctx, cancel := context.WithCancel(context.Background())
		a.cancel = cancel
		a.folder = folder
		a.state = taskState{Status: "运行中"}
		go a.download(ctx, target, req.Format, folder)
		w.WriteHeader(202)
	})
	mux.HandleFunc("POST /api/cancel", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.cancel != nil {
			a.cancel()
		}
		w.WriteHeader(204)
	})
	mux.HandleFunc("POST /api/open", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		folder := a.folder
		a.mu.Unlock()
		if err := os.MkdirAll(folder, 0755); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if err := launch(folder); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.WriteHeader(204)
	})
	mux.HandleFunc("POST /api/quit", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.cancel != nil {
			http.Error(w, "请先等待任务完成或取消任务", 409)
			return
		}
		w.WriteHeader(204)
		go func() { time.Sleep(300 * time.Millisecond); os.Exit(0) }()
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		if r.Host != strings.TrimPrefix(a.origin, "http://") ||
			(strings.HasPrefix(r.URL.Path, "/api/") && r.Header.Get("X-Bili-Token") != a.token) ||
			(r.Method == "POST" && r.Header.Get("Origin") != a.origin) {
			http.Error(w, "禁止访问", 403)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func main() {
	exe, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	var secret [24]byte
	if _, err := rand.Read(secret[:]); err != nil {
		log.Fatal(err)
	}
	tools := filepath.Join(filepath.Dir(exe), "tools")
	if runtime.GOOS == "darwin" && filepath.Base(filepath.Dir(exe)) == "MacOS" {
		tools = filepath.Join(filepath.Dir(exe), "..", "Resources", "tools")
	}
	a := &app{
		state:  taskState{Status: "待下载"},
		tools:  tools,
		folder: filepath.Join(home, "Downloads", "Bilibili"),
		origin: "http://" + listener.Addr().String(),
		token:  hex.EncodeToString(secret[:]),
	}
	server := &http.Server{Handler: a.routes(), ReadHeaderTimeout: 5 * time.Second}
	if runtime.GOOS == "windows" && os.Getenv("BILI_NO_OPEN") != "1" {
		go func() { log.Print(server.Serve(listener)) }()
		if err := desktop(a.origin, a.token); err != nil {
			log.Print(err)
		}
		a.mu.Lock()
		if a.cancel != nil {
			a.cancel()
		}
		a.mu.Unlock()
		return
	}
	fmt.Println(a.origin + "/?token=" + a.token)
	log.Fatal(server.Serve(listener))
}
