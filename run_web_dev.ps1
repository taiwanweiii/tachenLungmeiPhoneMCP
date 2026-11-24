# 開發用：在 Chrome 啟動 App，並關閉跨來源（CORS）檢查
# 只限本機開發測試，不要拿這個 Chrome 視窗瀏覽其他網站
#
# 用法：
#   .\run_web_dev.ps1            # 預設 port 5555
#   .\run_web_dev.ps1 -Port 6000

param(
    [int]$Port = 5555
)

Set-Location $PSScriptRoot

flutter run -d chrome `
    --web-port $Port `
    --web-browser-flag "--disable-web-security"
