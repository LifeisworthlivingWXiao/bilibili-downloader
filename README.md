# Bilibili 下载器

从 [GitHub Releases](https://github.com/LifeisworthlivingWXiao/bilibili-downloader/releases/latest) 下载与你的系统匹配的 ZIP。

1. 解压整个 ZIP。Windows 10/11 x64 双击 `BilibiliDownloader.exe`。macOS 11 及以上按芯片选择 Apple Silicon 或 Intel 包，双击 `Bilibili下载器.app`。
2. 应用会打开独立的桌面窗口。粘贴 B 站视频链接、b23.tv 分享链接、分享文本或 BV/av 号。多分 P 视频可用带 `?p=2` 等参数的链接指定分 P。
3. 选择 MP4 视频、MP3 音频或 M4A 音频。默认保存到用户目录的 `Downloads/Bilibili`，也可以点击「选择…」或填写其他绝对路径。
4. 下载完成后点「打开保存目录」。用完可关闭应用窗口。取消后可能保留部分文件，可用原任务继续下载。

ZIP 内含 yt-dlp、FFmpeg 和 FFprobe。应用无需安装 Python。下载需要联网。清晰度取决于 B 站向当前访问提供的流。应用没有登录入口，部分视频或清晰度可能需要账号权限。请下载你有权保存的内容。

Windows 程序未进行 Authenticode 签名。macOS 使用临时签名，未经过 Apple 公证。从网络获得的副本首次打开时可能受到系统拦截。

引擎来源：[yt-dlp 2026.10.26](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26)、[FFmpeg](https://ffmpeg.org/)、[FFmpeg npm 构建](https://github.com/kribblo/node-ffmpeg-installer)、[FFprobe npm 构建](https://github.com/SavageCore/node-ffprobe-installer)。

## 从源码构建

在 macOS 上准备 Go 1.24+、Python 3.11+、npm 和 Xcode Command Line Tools，执行 `python3 build.py`。也可在命令末尾指定 `Windows-x64`、`macOS-AppleSilicon` 或 `macOS-Intel`。输出位于 `dist/`。
