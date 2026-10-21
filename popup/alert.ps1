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
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshWin {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@ -ErrorAction Stop
    [void][DshWin]::SetProcessDPIAware()
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

    # A card must inform, not grab the keyboard. Prefer a form that overrides
    # ShowWithoutActivation; fall back to a plain form plus a foreground restore.
    $script:FormType = 'System.Windows.Forms.Form'
    $script:NoActivate = $false
    try {
        Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System.Windows.Forms;
public class DshCardForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            return cp;
        }
    }
}
'@ -ErrorAction Stop
        $script:FormType = 'DshCardForm'
        $script:NoActivate = $true
    } catch {
        $script:NoActivate = $false
    }

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
    $clientPid = 0
    $dismissOnClientFocus = $false
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
    if ($null -ne $payload.clientPid) {
        $parsedPid = 0.0
        if ([double]::TryParse(([string]$payload.clientPid).Trim(), [ref]$parsedPid)) { $clientPid = [int]$parsedPid }
    }
    if ($null -ne $payload.dismissOnClientFocus) {
        try { $dismissOnClientFocus = [System.Convert]::ToBoolean($payload.dismissOnClientFocus) } catch { $dismissOnClientFocus = $false }
    }

    # ---- client focus tracking ---------------------------------------------
    # The card must never cover the composer while the user answers. The Harness
    # window can belong to an ancestor of the spawning process (Electron main),
    # so track the client PID and its ancestors up to the shell.
    $clientPids = New-Object 'System.Collections.Generic.HashSet[int]'
    if ($dismissOnClientFocus -and $clientPid -gt 0) {
        try {
            $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
            $parentOf = @{}
            $nameOf = @{}
            foreach ($process in $processes) {
                $processId = [int]$process.ProcessId
                $parentOf[$processId] = [int]$process.ParentProcessId
                $nameOf[$processId] = [string]$process.Name
            }
            $stopNames = @('explorer.exe', 'winlogon.exe', 'services.exe', 'svchost.exe')
            $current = $clientPid
            for ($depth = 0; $depth -lt 8; $depth++) {
                if ($current -le 0) { break }
                [void]$clientPids.Add($current)
                if (-not $parentOf.ContainsKey($current)) { break }
                $parent = [int]$parentOf[$current]
                if ($parent -le 0) { break }
                if ($nameOf.ContainsKey($parent) -and $stopNames -contains $nameOf[$parent]) { break }
                $current = $parent
            }
            Write-Log ('client pids: ' + (($clientPids | Sort-Object) -join ','))
        } catch {
            Write-Log ('client pid lookup failed: ' + $_.Exception.Message)
        }
    }
    function Test-ClientFocused {
        if ($dismissOnClientFocus -eq $false -or $clientPids.Count -eq 0) {
            Write-Log ('focus check skipped: dismiss=' + $dismissOnClientFocus + ' pids=' + $clientPids.Count)
            return $false
        }
        $foreground = [DshWin]::GetForegroundWindow()
        if ($foreground -eq [IntPtr]::Zero) {
            Write-Log 'focus check: no foreground window'
            return $false
        }
        [uint32]$foregroundPid = 0
        [void][DshWin]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
        Write-Log ('focus check: foreground=' + $foregroundPid + ' match=' + $clientPids.Contains([int]$foregroundPid))
        if ($foregroundPid -eq 0) { return $false }
        return $clientPids.Contains([int]$foregroundPid)
    }

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
    $form = New-Object -TypeName $script:FormType
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

    # Never take the keyboard focus: remember the current owner and, for a plain
    # fallback form, hand it back right after showing.
    $previousForeground = [DshWin]::GetForegroundWindow()

    # Nothing to alert if the user is already looking at the Harness window.
    if (Test-ClientFocused) {
        Write-Log 'client already focused; card suppressed'
        try { $form.Dispose() } catch { }
        exit 0
    }

    if ($playSound) {
        try {
            if ($kind -eq 'need') { [System.Media.SystemSounds]::Exclamation.Play() }
            elseif ($kind -eq 'error') { [System.Media.SystemSounds]::Hand.Play() }
            else { [System.Media.SystemSounds]::Asterisk.Play() }
        } catch { }
    }

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $script:NoActivate -and $previousForeground -ne [IntPtr]::Zero) {
        try { [void][DshWin]::SetForegroundWindow($previousForeground) } catch { }
    }
    Write-Log ('shown noactivate=' + $script:NoActivate)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastFocusCheck = 0
    while (-not $script:Closed) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
        $elapsed = $watch.ElapsedMilliseconds
        if ($durationMs -gt 0 -and $elapsed -ge $durationMs) { break }
        if ($clientPids.Count -gt 0 -and ($elapsed - $lastFocusCheck) -ge 250) {
            $lastFocusCheck = $elapsed
            if (Test-ClientFocused) {
                Write-Log 'client focused; closing card'
                $script:Closed = $true
            }
        }
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
