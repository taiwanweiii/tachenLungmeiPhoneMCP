# 讓手機透過 USB 連到這台電腦的服務（手機上的 127.0.0.1 → 電腦）
#   1987  = MCP Server
#   30000 = 系統櫃網頁（Vite 開發伺服器）
#
# 用法：
#   .\tool\adb_reverse.ps1          補一次轉接後結束
#   .\tool\adb_reverse.ps1 -Watch   一直開著，USB 拔插或 adb 重啟後自動補回（Ctrl+C 結束）
#
# 為什麼需要：adb reverse 在 USB 重插、手機重開、adb 重啟後都會被清掉，
# 清掉之後 App 會顯示 Connection refused。
param(
    [switch]$Watch,
    [int[]]$Ports = @(1987, 30000)
)

function Ensure-Reverse {
    $devices = (adb devices) -split "`n" | Where-Object { $_ -match "`tdevice$" }
    if (-not $devices) { return $false }
    $current = (adb reverse --list) -join "`n"
    $changed = $false
    foreach ($p in $Ports) {
        if ($current -notmatch "tcp:$p tcp:$p") {
            adb reverse "tcp:$p" "tcp:$p" | Out-Null
            $changed = $true
        }
    }
    if ($changed) {
        Write-Host ("[{0}] 已補上轉接：{1}" -f (Get-Date -Format 'HH:mm:ss'), ($Ports -join ', '))
    }
    return $true
}

if (-not $Watch) {
    if (Ensure-Reverse) {
        adb reverse --list
    } else {
        Write-Host '找不到手機（請確認 USB 已連接並開啟 USB 偵錯）' -ForegroundColor Yellow
        exit 1
    }
    exit 0
}

Write-Host "監看中，USB 轉接掉了會自動補回（Ctrl+C 結束）。埠：$($Ports -join ', ')"
while ($true) {
    [void](Ensure-Reverse)
    Start-Sleep -Seconds 3
}
