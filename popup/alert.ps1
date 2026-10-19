# alert.ps1 -- topmost desktop alert card for the DSH topmost-alert host plugin.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File alert.ps1 -PayloadFile <abs.json>
#
# Pure ASCII source: every localized string comes from the UTF-8 JSON payload, so
# an ANSI code page host cannot corrupt this file. Windows PowerShell 5.1 and
# PowerShell 7.x compatible. One invocation == one window.

param(
    [string]$PayloadFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

# Windows scales a DPI-unaware process's windows and reports virtualized screen
# coordinates, which pushes a "bottom-right" card off the real desktop on a
# scaled display. Declare awareness before any window or Screen query.
try {
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class DshDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }' -ErrorAction Stop
    [void][DshDpi]::SetProcessDPIAware()
} catch { }

$script:DebugLog = $null
if (-not [string]::IsNullOrEmpty($env:DSH_ALERT_DEBUG)) {
    try { $script:DebugLog = Join-Path $env:TEMP 'dsh-alert-debug.log' } catch { $script:DebugLog = $null }
}

function Write-Log {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($script:DebugLog)) { return }
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($script:DebugLog, ('[' + $stamp + '] ' + $Message + [Environment]::NewLine), $utf8)
    } catch { }
}

try {
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ([string]::IsNullOrEmpty($PayloadFile) -or -not (Test-Path -LiteralPath $PayloadFile)) {
        Write-Log 'payload missing'
        exit 0
    }
    $raw = Get-Content -LiteralPath $PayloadFile -Raw -Encoding UTF8
    if ([string]::IsNullOrEmpty($raw)) { Write-Log 'payload empty'; exit 0 }
    $payload = $raw | ConvertFrom-Json
    if ($null -eq $payload) { Write-Log 'payload unreadable'; exit 0 }

    # ---- fields -------------------------------------------------------------
    $title = 'DSH'
    $subtitle = ''
    $body = ''
    $kind = 'done'
    $durationMs = 20000
    $playSound = $true
    $position = 'bottom-right'
    $index = 0
    if ($null -ne $payload.title) { $title = ([string]$payload.title).Trim() }
    if ($null -ne $payload.subtitle) { $subtitle = ([string]$payload.subtitle).Trim() }
    if ($null -ne $payload.body) { $body = [string]$payload.body }
    if ($null -ne $payload.kind) { $kind = ([string]$payload.kind).Trim().ToLowerInvariant() }
    if ($null -ne $payload.durationMs) {
        $parsed = 0.0
        if ([double]::TryParse(([string]$payload.durationMs).Trim(), [ref]$parsed)) { $durationMs = [int]$parsed }
    }
    if ($durationMs -lt 0) { $durationMs = 0 }
    if ($null -ne $payload.sound) {
        try { $playSound = [System.Convert]::ToBoolean($payload.sound) } catch { $playSound = $true }
    }
    if ($null -ne $payload.position) { $position = ([string]$payload.position).Trim().ToLowerInvariant() }
    if (-not ($position -eq 'bottom-right' -or $position -eq 'top-right' -or $position -eq 'bottom-left' -or $position -eq 'top-left')) {
        $position = 'bottom-right'
    }
    if ($null -ne $payload.index) {
        $parsedIndex = 0.0
        if ([double]::TryParse(([string]$payload.index).Trim(), [ref]$parsedIndex)) { $index = [int]$parsedIndex }
    }
    if ($index -lt 0) { $index = 0 }
    if ($index -gt 12) { $index = 12 }

    # ---- palette ------------------------------------------------------------
    $accent = [System.Drawing.Color]::FromArgb(0x3F, 0xB9, 0x50)
    if ($kind -eq 'need') { $accent = [System.Drawing.Color]::FromArgb(0xD2, 0x99, 0x22) }
    elseif ($kind -eq 'error') { $accent = [System.Drawing.Color]::FromArgb(0xF8, 0x51, 0x49) }
    $bg = [System.Drawing.Color]::FromArgb(0x1E, 0x1E, 0x24)
    $titleFg = [System.Drawing.Color]::FromArgb(0xF2, 0xF3, 0xF5)
    $subFg = [System.Drawing.Color]::FromArgb(0x9A, 0xA0, 0xA8)
    $bodyFg = [System.Drawing.Color]::FromArgb(0xC7, 0xCC, 0xD3)
    $closeFg = [System.Drawing.Color]::FromArgb(0x86, 0x8C, 0x95)

    # ---- fonts (DPI aware) --------------------------------------------------
    $dpiScale = 1.0
    try {
        $dc = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        if ($null -ne $dc) {
            $dpiScale = [double]$dc.DpiY / 96.0
            $dc.Dispose()
        }
    } catch { $dpiScale = 1.0 }
    if ($dpiScale -lt 1.0) { $dpiScale = 1.0 }
    if ($dpiScale -gt 3.0) { $dpiScale = 3.0 }

    $families = @{}
    try { foreach ($f in [System.Drawing.FontFamily]::Families) { $families[[string]$f.Name] = $true } } catch { }
    $textFamily = 'Segoe UI'
    if (-not $families.ContainsKey($textFamily)) { $textFamily = 'Arial' }
    $hasCjk = $false
    $all = $title + $subtitle + $body
    for ($i = 0; $i -lt $all.Length; $i++) {
        $code = [int][char]$all[$i]
        if (($code -ge 0x2E80 -and $code -le 0x9FFF) -or ($code -ge 0xFF00 -and $code -le 0xFFEF)) { $hasCjk = $true; break }
    }
    if ($hasCjk) {
        if ($families.ContainsKey('Microsoft YaHei UI')) { $textFamily = 'Microsoft YaHei UI' }
        elseif ($families.ContainsKey('Microsoft YaHei')) { $textFamily = 'Microsoft YaHei' }
    }
    $titleFont = New-Object System.Drawing.Font($textFamily, [single]14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $subFont = New-Object System.Drawing.Font($textFamily, [single]9, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
    $bodyFont = New-Object System.Drawing.Font($textFamily, [single]10.5, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)

    $cardWidth = [int][Math]::Round(420 * $dpiScale)
    $padX = [int][Math]::Round(20 * $dpiScale)
    $padY = [int][Math]::Round(16 * $dpiScale)
    $innerWidth = $cardWidth - ($padX * 2)
    $closeSize = [int][Math]::Round(24 * $dpiScale)
    $lineHeight = [int][Math]::Ceiling($bodyFont.GetHeight() * 1.35)
    if ($lineHeight -lt 16) { $lineHeight = [int][Math]::Ceiling(18 * $dpiScale) }

    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $bodySize = [System.Windows.Forms.TextRenderer]::MeasureText($body, $bodyFont, (New-Object System.Drawing.Size($innerWidth, 4000)), $measureFlags)
    $bodyHeight = [int][Math]::Min($bodySize.Height + 2, ($lineHeight * 3) + 4)
    if ([string]::IsNullOrEmpty($body)) { $bodyHeight = 0 }

    $titleHeight = [int][Math]::Ceiling($titleFont.GetHeight() * 1.25)
    $subHeight = 0
    if ($subtitle.Length -gt 0) { $subHeight = [int][Math]::Ceiling($subFont.GetHeight() * 1.25) }

    $contentHeight = $titleHeight + $subHeight + $bodyHeight
    if ($subHeight -gt 0) { $contentHeight += [int][Math]::Round(2 * $dpiScale) }
    if ($bodyHeight -gt 0) { $contentHeight += [int][Math]::Round(8 * $dpiScale) }
    $cardHeight = $contentHeight + ($padY * 2)
    if ($cardHeight -lt [int][Math]::Round(112 * $dpiScale)) { $cardHeight = [int][Math]::Round(112 * $dpiScale) }

    # ---- form ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'DSH Alert'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.ControlBox = $false
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowIcon = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.BackColor = $bg
    $form.ForeColor = $titleFg
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.ClientSize = New-Object System.Drawing.Size($cardWidth, $cardHeight)
    $form.Padding = New-Object System.Windows.Forms.Padding(0)

    $accentBar = New-Object System.Windows.Forms.Panel
    $accentBar.BackColor = $accent
    $accentBar.Location = New-Object System.Drawing.Point(0, 0)
    $accentBar.Size = New-Object System.Drawing.Size([int][Math]::Round(4 * $dpiScale), $cardHeight)
    $form.Controls.Add($accentBar)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $title
    $titleLabel.Font = $titleFont
    $titleLabel.ForeColor = $titleFg
    $titleLabel.BackColor = $bg
    $titleLabel.AutoSize = $false
    $titleLabel.AutoEllipsis = $true
    $titleLabel.UseMnemonic = $false
    $titleLabel.Location = New-Object System.Drawing.Point($padX, $padY)
    $titleLabel.Size = New-Object System.Drawing.Size(($innerWidth - $closeSize - 8), $titleHeight)
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $form.Controls.Add($titleLabel)

    $closeLabel = New-Object System.Windows.Forms.Label
    $closeLabel.Text = 'X'
    $closeLabel.Font = New-Object System.Drawing.Font($textFamily, [single]10, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
    $closeLabel.ForeColor = $closeFg
    $closeLabel.BackColor = $bg
    $closeLabel.AutoSize = $false
    $closeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $closeLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $closeLabel.Location = New-Object System.Drawing.Point(($cardWidth - $padX - $closeSize), $padY)
    $closeLabel.Size = New-Object System.Drawing.Size($closeSize, $titleHeight)
    $form.Controls.Add($closeLabel)

    $subLabel = $null
    if ($subHeight -gt 0) {
        $subLabel = New-Object System.Windows.Forms.Label
        $subLabel.Text = $subtitle
        $subLabel.Font = $subFont
        $subLabel.ForeColor = $subFg
        $subLabel.BackColor = $bg
        $subLabel.AutoSize = $false
        $subLabel.AutoEllipsis = $true
        $subLabel.UseMnemonic = $false
        $subLabel.Location = New-Object System.Drawing.Point($padX, ($padY + $titleHeight))
        $subLabel.Size = New-Object System.Drawing.Size($innerWidth, $subHeight)
        $subLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $form.Controls.Add($subLabel)
    }

    if ($bodyHeight -gt 0) {
        $bodyLabel = New-Object System.Windows.Forms.Label
        $bodyLabel.Text = $body
        $bodyLabel.Font = $bodyFont
        $bodyLabel.ForeColor = $bodyFg
        $bodyLabel.BackColor = $bg
        $bodyLabel.AutoSize = $false
        $bodyLabel.UseMnemonic = $false
        $bodyY = $padY + $titleHeight + $subHeight
        if ($subHeight -gt 0) { $bodyY += [int][Math]::Round(2 * $dpiScale) }
        if ($bodyHeight -gt 0) { $bodyY += [int][Math]::Round(8 * $dpiScale) }
        $bodyLabel.Location = New-Object System.Drawing.Point($padX, $bodyY)
        $bodyLabel.Size = New-Object System.Drawing.Size($innerWidth, $bodyHeight)
        $form.Controls.Add($bodyLabel)
    }

    # ---- dock position ------------------------------------------------------
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $edge = [int][Math]::Round(16 * $dpiScale)
    $stackStep = [int][Math]::Round(112 * $dpiScale) * $index
    if ($position.StartsWith('top')) {
        $formY = $workArea.Top + $edge + $stackStep
        if ($formY + $cardHeight -gt $workArea.Bottom) { $formY = $workArea.Bottom - $edge - $cardHeight }
    } else {
        $formY = $workArea.Bottom - $edge - $cardHeight - $stackStep
        if ($formY -lt $workArea.Top) { $formY = $workArea.Top + $edge }
    }
    if ($position.EndsWith('left')) {
        $formX = $workArea.Left + $edge
    } else {
        $formX = $workArea.Right - $edge - $cardWidth
    }
    if ($formX -lt $workArea.Left) { $formX = $workArea.Left + $edge }
    $form.Location = New-Object System.Drawing.Point($formX, $formY)
    Write-Log ('card size=' + $cardWidth + 'x' + $cardHeight + ' at=' + $formX + ',' + $formY + ' kind=' + $kind)

    # ---- behavior -----------------------------------------------------------
    $script:Closed = $false
    $closeLabel.Add_Click({ $script:Closed = $true })
    $accentBar.Add_Click({ $script:Closed = $true })
    $titleLabel.Add_Click({ $script:Closed = $true })
    if ($null -ne $subLabel) { $subLabel.Add_Click({ $script:Closed = $true }) }
    $form.Add_MouseClick({ $script:Closed = $true })
    $form.Add_KeyDown({ param($s, $e) if ($null -ne $e -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:Closed = $true } })
    $closeLabel.Add_MouseEnter({ $closeLabel.ForeColor = $titleFg })
    $closeLabel.Add_MouseLeave({ $closeLabel.ForeColor = $closeFg })

    if ($playSound) {
        try {
            if ($kind -eq 'need') { [System.Media.SystemSounds]::Exclamation.Play() }
            elseif ($kind -eq 'error') { [System.Media.SystemSounds]::Hand.Play() }
            else { [System.Media.SystemSounds]::Asterisk.Play() }
        } catch { }
    }

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Write-Log 'shown'

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $script:Closed) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
        if ($durationMs -gt 0 -and $watch.ElapsedMilliseconds -ge $durationMs) { break }
    }
    $watch.Stop()
    Write-Log ('closed after ' + $watch.ElapsedMilliseconds + 'ms')

    try { $form.Hide() } catch { }
    try { $form.Close() } catch { }
    try { $form.Dispose() } catch { }
    exit 0
} catch {
    Write-Log ('fatal: ' + $_.Exception.ToString())
    exit 0
}
