Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'Bilibili 下载器'
$form.ClientSize = New-Object Drawing.Size(680, 490)
$form.AutoScaleMode = 'Dpi'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
function Control($type, $text, $x, $y, $w, $h) {
    $c = New-Object "Windows.Forms.$type"
    $c.Text = $text
    $c.SetBounds($x, $y, $w, $h)
    $form.Controls.Add($c)
    return $c
}
$title = Control Label 'Bilibili 下载器' 22 15 620 40
$title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 21, [Drawing.FontStyle]::Bold)
$null = Control Label '视频地址 · B 站链接、分享文本或 BV/av 号' 24 65 630 24
$link = Control TextBox '' 24 90 630 28
$null = Control Label '输出格式' 24 132 100 25
$format = Control ComboBox '' 126 127 180 30
$format.DropDownStyle = 'DropDownList'
$format.Items.AddRange(@('MP4 视频','MP3 音频','M4A 音频'))
$format.SelectedIndex = 0
$null = Control Label '保存目录' 24 171 100 25
$folder = Control TextBox '' 126 167 435 28
$choose = Control Button '选择…' 570 164 84 31
$start = Control Button '开始下载' 24 215 105 35
$cancel = Control Button '取消任务' 138 215 105 35
$open = Control Button '打开保存目录' 252 215 132 35
$status = Control Label '正在连接' 24 263 630 27
$logs = Control TextBox '' 24 294 630 170
$logs.Multiline = $true
$logs.ReadOnly = $true
$logs.ScrollBars = 'Vertical'
$form.AcceptButton = $start
$cancel.Enabled = $false
$script:running = $false
$script:initialized = $false
function CallApi($action, $payload) {
    $headers = @{ 'X-Bili-Token' = $env:BILI_TOKEN }
    if ($action -eq 'state') {
        return Invoke-RestMethod -UseBasicParsing -Uri "$env:BILI_ORIGIN/api/state" -Headers $headers -TimeoutSec 2
    }
    $headers.Origin = $env:BILI_ORIGIN
    $body = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
    Invoke-RestMethod -UseBasicParsing -Uri "$env:BILI_ORIGIN/api/$action" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 3
}
function RefreshState {
    $state = CallApi 'state'
    if (!$script:initialized) { $folder.Text = $state.folder; $script:initialized = $true }
    $script:running = $state.status -eq '运行中'
    $start.Enabled = !$script:running
    $cancel.Enabled = $script:running
    $status.Text = $state.status
    $message = ($state.log -join [Environment]::NewLine)
    if ($state.file) { $message += [Environment]::NewLine + $state.file }
    if ($logs.Text -ne $message) {
        $logs.Text = $message
        $logs.SelectionStart = $logs.TextLength
        $logs.ScrollToCaret()
    }
}
function RunAction($action, $data) {
    try { $null = CallApi $action $data; RefreshState }
    catch {
        $message = $_.ErrorDetails.Message
        if (!$message) { $message = $_.Exception.Message }
        [void][Windows.Forms.MessageBox]::Show($form, $message, 'Bilibili 下载器')
    }
}
$start.Add_Click({
    RunAction 'start' @{ url = $link.Text; folder = $folder.Text; format = @('mp4','mp3','m4a')[$format.SelectedIndex] }
})
$cancel.Add_Click({ RunAction 'cancel' @{} })
$open.Add_Click({ RunAction 'open' @{} })
$choose.Add_Click({
    $picker = New-Object Windows.Forms.FolderBrowserDialog
    try {
        $picker.SelectedPath = $folder.Text
        if ($picker.ShowDialog($form) -eq 'OK') { $folder.Text = $picker.SelectedPath }
    } finally { $picker.Dispose() }
})
$form.Add_FormClosing({
    if ($script:running) {
        $_.Cancel = $true
        [void][Windows.Forms.MessageBox]::Show($form, '请先取消任务，或等待下载完成。', 'Bilibili 下载器')
    }
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({ try { RefreshState } catch { $status.Text = '无法连接下载引擎'; $start.Enabled = $false } })
$start.Enabled = $false
$timer.Start()
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
