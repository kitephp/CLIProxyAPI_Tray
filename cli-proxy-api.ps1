#Requires -Version 5.1

<#
.SYNOPSIS
    CLIProxyAPI Tray - Windows System Tray Application
.DESCRIPTION
    A system tray application for managing CLIProxyAPI.
    Features:
    - Single instance enforcement via mutex
    - Start/stop/restart CLIProxyAPI
    - Automatic version download/update from GitHub
    - Shared config.yaml management
    - Password prompt for remote management
    - System tray menu interface
.NOTES
    Version: 2.0.0
    Author: KitePHP
    Requirements: Windows 10+, PowerShell 5.1+
#>

#region Configuration Constants
$script:Config = @{
    # Application
    AppName = "CLIProxyAPI Tray"
    TrayVersion = "2.0.0"
    MutexName = "Global\CLIProxyAPI_Tray_SingleInstance"

    # GitHub Repositories
    Repository = "router-for-me/CLIProxyAPI"
    ProjectUrl = "https://github.com/kitephp/CLIProxyAPI-Tray"

    # Process Names (without .exe)
    ProcessName = "cli-proxy-api"

    # Default Values
    DefaultPort = 8317
    DefaultShowProgress = $true
    PortCheckTimeout = 500
    StartupTimeout = 12000

    # UI Settings
    BalloonTipDuration = 1500
    TimerInterval = 1000
}
#endregion

#region Windows API Declarations
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32API {
    // DPI Awareness
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

    // Console Window Management
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public const int SW_HIDE = 0;
    public const int SW_SHOW = 5;
}
"@
#endregion

#region Assembly Loading
Add-Type -AssemblyName System.Threading
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
#endregion

#region Initialization
function Get-PowerShellHostPath {
    <#
    .SYNOPSIS
        Resolve the current PowerShell host executable path.
    #>
    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        if ($currentProcess.Path -and (Test-Path -LiteralPath $currentProcess.Path)) {
            return $currentProcess.Path
        }
    }
    catch {
        Write-Verbose "Failed to resolve current PowerShell host path"
    }

    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell) {
        return $windowsPowerShell
    }

    return "powershell.exe"
}

function Initialize-Application {
    <#
    .SYNOPSIS
        Initialize application environment
    #>

    # Hide console window
    $consolePtr = [Win32API]::GetConsoleWindow()
    if ($consolePtr -ne [IntPtr]::Zero) {
        [Win32API]::ShowWindow($consolePtr, [Win32API]::SW_HIDE) | Out-Null
    }

    # Enable DPI awareness (Per-Monitor V2)
    try {
        [Win32API]::SetProcessDpiAwarenessContext(
            [Win32API]::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        ) | Out-Null
    }
    catch {
        Write-Verbose "DPI awareness not supported on this Windows version"
    }

    # Enforce single instance via mutex
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex($true, $script:Config.MutexName, [ref]$createdNew)

    if (-not $createdNew) {
        Write-Warning "Another instance is already running"
        exit 0
    }

    # Ensure STA mode for WinForms
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Start-Process -FilePath (Get-PowerShellHostPath) -ArgumentList @(
            "-STA", "-NoProfile", "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
        )
        exit 0
    }
}

Initialize-Application
#endregion

#region Path Definitions
$script:LocalDataRoot = if ($env:LOCALAPPDATA) {
    $env:LOCALAPPDATA
}
elseif ($env:APPDATA) {
    $env:APPDATA
}
else {
    $PSScriptRoot
}

$script:Paths = @{
    BaseDir       = $PSScriptRoot
    DataDir       = Join-Path $script:LocalDataRoot "CLIProxyAPI_Tray"
    Config        = Join-Path $PSScriptRoot "config.yaml"
    ConfigExample = Join-Path $PSScriptRoot "config.example.yaml"
    Icon          = Join-Path $PSScriptRoot "cli-proxy-api.ico"
    VersionsDir   = Join-Path $PSScriptRoot "versions"
    SettingsFile  = Join-Path $PSScriptRoot "settings.json"
    SettingsFileFallback = Join-Path (Join-Path $script:LocalDataRoot "CLIProxyAPI_Tray") "settings.json"
    LogDir        = Join-Path $PSScriptRoot "logs"
}
#endregion

#region State Management
$script:State = @{
    version     = $null    # tag e.g. v6.7.37
    arch        = $null    # amd64 | arm64
    autoOpenWebUI = $true  # start/restart auto-open behavior
    autoUpdate  = $false   # check and install updates on tray startup
}

function Get-SystemArchitecture {
    <#
    .SYNOPSIS
        Detect system architecture
    .OUTPUTS
        String - "amd64" or "arm64"
    #>
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    return $(if ($arch -eq "Arm64") { "aarch64" } else { "amd64" })
}

function Test-DirectoryWritable {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        $testFile = Join-Path $Path (".write_test_" + [Guid]::NewGuid().ToString("N") + ".tmp")
        try {
            Set-Content -LiteralPath $testFile -Value "1" -Encoding ASCII -ErrorAction Stop
        }
        finally {
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-SettingsCandidate {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [bool]$IsFallback = $false
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $object = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
                  ConvertFrom-Json -ErrorAction Stop

        return [PSCustomObject]@{
            Path         = $item.FullName
            Object       = $object
            LastWriteUtc = $item.LastWriteTimeUtc
            IsFallback   = $IsFallback
        }
    }
    catch {
        Write-Warning "Failed to read settings candidate '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Get-SettingsWritePath {
    param(
        [object]$Candidate = $null
    )

    if ($Candidate -and [bool]$Candidate.IsFallback) {
        return $script:Paths.SettingsFileFallback
    }

    $primaryDir = Split-Path -Parent $script:Paths.SettingsFile
    if ($primaryDir -and (-not (Test-DirectoryWritable -Path $primaryDir))) {
        return $script:Paths.SettingsFileFallback
    }

    return $script:Paths.SettingsFile
}

function Import-State {
    <#
    .SYNOPSIS
        Load settings from JSON file
    #>
    $candidates = @(
        Get-SettingsCandidate -Path $script:Paths.SettingsFile
        Get-SettingsCandidate -Path $script:Paths.SettingsFileFallback -IsFallback $true
    ) | Where-Object { $null -ne $_ }

    if (-not $candidates -or $candidates.Count -eq 0) {
        return
    }

    $candidate = $candidates |
                 Sort-Object -Property LastWriteUtc -Descending |
                 Select-Object -First 1

    try {
        $obj = $candidate.Object

        if ($obj.version) { $script:State.version = [string]$obj.version }
        if ($obj.arch)    { $script:State.arch = [string]$obj.arch }
        if ($null -ne $obj.autoOpenWebUI) {
            $script:State.autoOpenWebUI = [bool]$obj.autoOpenWebUI
        }
        if ($null -ne $obj.autoUpdate) {
            $script:State.autoUpdate = [bool]$obj.autoUpdate
        }

        $script:Paths.SettingsFile = Get-SettingsWritePath -Candidate $candidate
    }
    catch {
        Write-Warning "Failed to load settings: $($_.Exception.Message)"
    }
}

function Export-State {
    <#
    .SYNOPSIS
        Save current settings to JSON file
    #>
    try {
        $stateObject = [PSCustomObject]@{
            version     = $script:State.version
            arch        = $script:State.arch
            autoOpenWebUI = [bool]$script:State.autoOpenWebUI
            autoUpdate  = [bool]$script:State.autoUpdate
            updatedAt   = (Get-Date).ToString("o")
        }

        $json = $stateObject | ConvertTo-Json -Compress

        try {
            $settingsDir = Split-Path -Parent $script:Paths.SettingsFile
            if ($settingsDir) {
                New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
            }

            $json | Set-Content -LiteralPath $script:Paths.SettingsFile -Encoding UTF8 -ErrorAction Stop
            return $true
        }
        catch {
            # 脚本目录可能不可写（例如放在 Program Files），则降级写到用户目录。
            $primaryErr = $_.Exception.Message

            try {
                $fallbackPath = $script:Paths.SettingsFileFallback
                $fallbackDir = Split-Path -Parent $fallbackPath
                if ($fallbackDir) {
                    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
                }

                $json | Set-Content -LiteralPath $fallbackPath -Encoding UTF8 -ErrorAction Stop

                # 后续统一用可写路径，避免每次保存都失败。
                $script:Paths.SettingsFile = $fallbackPath

                if (-not $script:StateFileWriteFallbackNotified) {
                    $script:StateFileWriteFallbackNotified = $true
                    Show-BalloonTip "settings.json 保存失败（$primaryErr），已改为写入：$fallbackPath" -Icon Warning -Duration 2500
                }
                return $true
            }
            catch {
                if (-not $script:StateFileWriteFailedNotified) {
                    $script:StateFileWriteFailedNotified = $true
                    Show-BalloonTip "settings.json 保存失败：$primaryErr" -Icon Error -Duration 2500
                }
                Write-Warning "Failed to save settings: $primaryErr"
                return $false
            }
        }
    }
    catch {
        Write-Warning "Failed to save settings: $($_.Exception.Message)"
        return $false
    }
}
#endregion

#region Tray Icon Initialization
function Get-ApplicationIcon {
    <#
    .SYNOPSIS
        Load the application icon from the project directory.
    #>
    try {
        if ($script:Paths.Icon -and (Test-Path -LiteralPath $script:Paths.Icon)) {
            return (New-Object System.Drawing.Icon($script:Paths.Icon))
        }
    }
    catch {
        Write-Warning "Failed to load tray icon: $($_.Exception.Message)"
    }

    return ([System.Drawing.Icon][System.Drawing.SystemIcons]::Application.Clone())
}

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = Get-ApplicationIcon
$script:TrayIcon.Visible = $true
$script:TrayIcon.Text = $script:Config.AppName
#endregion

#region Configuration Management
function Test-ConfigExists {
    <#
    .SYNOPSIS
        Ensure config.yaml exists, create from example if missing
    .OUTPUTS
        Boolean - $true if config exists or was created successfully
    #>
    if (Test-Path $script:Paths.Config) {
        return $true
    }

    if (-not (Test-Path $script:Paths.ConfigExample)) {
        [System.Windows.Forms.MessageBox]::Show(
            "config.yaml is missing and config.example.yaml was not found.`nCannot continue.",
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }

    try {
        Copy-Item -LiteralPath $script:Paths.ConfigExample -Destination $script:Paths.Config -Force
        Show-BalloonTip "Created config.yaml from config.example.yaml" -Icon Info
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to create config.yaml:`n$($_.Exception.Message)",
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Extract a value from config.yaml
    .PARAMETER Key
        The YAML key to search for
    .PARAMETER Pattern
        Regex pattern to match the value
    .PARAMETER Default
        Default value if not found
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [object]$Default = $null
    )

    if (-not (Test-Path $script:Paths.Config)) {
        return $Default
    }

    try {
        $line = Get-Content -LiteralPath $script:Paths.Config -ErrorAction Stop |
                Where-Object { $_ -match "^\s*$Key\s*:\s*$Pattern" } |
                Select-Object -First 1

        if ($line -and ($line -match "^\s*$Key\s*:\s*(.+)")) {
            return $Matches[1].Trim()
        }
    }
    catch {
        Write-Warning "Failed to read config value '$Key': $($_.Exception.Message)"
    }

    return $Default
}

function Get-PortFromConfig {
    <#
    .SYNOPSIS
        Get port number from config.yaml
    #>
    param([int]$DefaultPort = $script:Config.DefaultPort)

    $portValue = Get-ConfigValue -Key "port" -Pattern "\d+" -Default $DefaultPort

    if ($portValue -match '^\d+$') {
        return [int]$portValue
    }

    return $DefaultPort
}

function Get-ShowUpdateProgressFromConfig {
    <#
    .SYNOPSIS
        Get show-update-progress setting from config.yaml
    #>
    param([bool]$Default = $script:Config.DefaultShowProgress)

    $value = Get-ConfigValue -Key "show-update-progress" -Pattern "(true|false)" -Default $Default.ToString().ToLower()

    return ($value -eq 'true')
}

function Get-SecretKeyFromConfig {
    <#
    .SYNOPSIS
        Extract secret-key from config.yaml
    .OUTPUTS
        String - The secret key value, or empty string if not found
    #>
    if (-not (Test-Path $script:Paths.Config)) {
        return ""
    }

    try {
        $lines = Get-Content -LiteralPath $script:Paths.Config -ErrorAction Stop

        foreach ($line in $lines) {
            if ($line -match '^\s*secret-key\s*:\s*(.+)\s*$') {
                $value = $Matches[1].Trim()

                # Remove quotes if present
                if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
                    $value = $Matches[1]
                }

                return $value.Trim()
            }
        }
    }
    catch {
        Write-Warning "Failed to read secret-key: $($_.Exception.Message)"
    }

    return ""
}

function Set-SecretKeyInConfig {
    <#
    .SYNOPSIS
        Update secret-key in config.yaml
    .PARAMETER NewKey
        The new secret key value
    .OUTPUTS
        Boolean - $true if successful
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NewKey
    )

    if (-not (Test-Path $script:Paths.Config)) {
        return $false
    }

    try {
        $lines = Get-Content -LiteralPath $script:Paths.Config -ErrorAction Stop
        $updated = $false

        # Replace existing secret-key
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*secret-key\s*:') {
                $indent = ($lines[$i] -replace '^(\s*).*$', '$1')
                $lines[$i] = "${indent}secret-key: `"$NewKey`""
                $updated = $true
                break
            }
        }

        # If not found, insert into remote-management section
        if (-not $updated) {
            $rmIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*remote-management\s*:\s*$') {
                    $rmIndex = $i
                    break
                }
            }

            if ($rmIndex -ge 0) {
                # Find insertion point (end of remote-management block)
                $insertAt = $rmIndex + 1
                for ($j = $rmIndex + 1; $j -lt $lines.Count; $j++) {
                    if ($lines[$j] -match '^\S') {
                        $insertAt = $j
                        break
                    }
                    $insertAt = $j + 1
                }

                # Check if allow-remote exists
                $hasAllow = $false
                for ($k = $rmIndex + 1; $k -lt $lines.Count; $k++) {
                    if ($lines[$k] -match '^\S') { break }
                    if ($lines[$k] -match '^\s*allow-remote\s*:') {
                        $hasAllow = $true
                        break
                    }
                }

                # Build insertion block
                $block = @()
                if (-not $hasAllow) {
                    $block += '  allow-remote: false'
                }
                $block += "  secret-key: `"$NewKey`""

                # Insert block
                if ($insertAt -le 0) {
                    $lines = @($lines + $block)
                }
                else {
                    $lines = @($lines[0..($insertAt - 1)] + $block + $lines[$insertAt..($lines.Count - 1)])
                }
            }
            else {
                # Add new remote-management section
                $lines = @(
                    $lines +
                    "" +
                    "remote-management:" +
                    "  allow-remote: false" +
                    "  secret-key: `"$NewKey`""
                )
            }
        }

        $lines | Set-Content -LiteralPath $script:Paths.Config -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "Failed to update secret-key: $($_.Exception.Message)"
        return $false
    }
}

function Request-Password {
    <#
    .SYNOPSIS
        Prompt user for password input
    .OUTPUTS
        String - The password, or empty string if cancelled
    #>
    param(
        [string]$Title = "Password Required",
        [string]$Prompt = "Please enter password:"
    )

    while ($true) {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.ClientSize = New-Object System.Drawing.Size(460, 180)
        $form.StartPosition = "CenterScreen"
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ShowInTaskbar = $true
        $form.TopMost = $true
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.Dock = "Fill"
        $layout.Padding = New-Object System.Windows.Forms.Padding(16)
        $layout.ColumnCount = 1
        $layout.RowCount = 3
        $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 62))) | Out-Null
        $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null
        $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
        $form.Controls.Add($layout)

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Prompt
        $label.Dock = "Fill"
        $label.TextAlign = "MiddleLeft"
        $layout.Controls.Add($label, 0, 0)

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Dock = "Fill"
        $textBox.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
        $textBox.UseSystemPasswordChar = $true
        $layout.Controls.Add($textBox, 0, 1)

        $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttonPanel.Dock = "Fill"
        $buttonPanel.FlowDirection = "RightToLeft"
        $buttonPanel.WrapContents = $false
        $buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
        $layout.Controls.Add($buttonPanel, 0, 2)

        $okButton = New-Object System.Windows.Forms.Button
        $okButton.Text = "OK"
        $okButton.Size = New-Object System.Drawing.Size(75, 28)
        $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $buttonPanel.Controls.Add($okButton)

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Text = "Cancel"
        $cancelButton.Size = New-Object System.Drawing.Size(75, 28)
        $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $buttonPanel.Controls.Add($cancelButton)

        $form.AcceptButton = $okButton
        $form.CancelButton = $cancelButton
        $form.Add_Shown({ $textBox.Focus() })

        try {
            $result = $form.ShowDialog()
            if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
                return ""
            }

            $password = $textBox.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($password)) {
                return $password
            }

            [System.Windows.Forms.MessageBox]::Show(
                "Password cannot be empty.",
                $Title,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        finally {
            $form.Dispose()
        }
    }
}

function Test-PasswordConfigured {
    <#
    .SYNOPSIS
        Ensure password is set in config, prompt if missing
    .OUTPUTS
        Boolean - $true if password is configured
    #>
    if (-not (Test-ConfigExists)) {
        return $false
    }

    $key = Get-SecretKeyFromConfig
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        return $true
    }

    $password = Request-Password -Title "Set Password" -Prompt "config.yaml secret-key is empty.`nPlease enter a password:"

    if ([string]::IsNullOrWhiteSpace($password)) {
        return $false
    }

    if (Set-SecretKeyInConfig $password) {
        Show-BalloonTip "Password saved to config.yaml" -Icon Info
        return $true
    }

    Show-BalloonTip "Failed to write password to config.yaml" -Icon Error -Duration 2000
    return $false
}
#endregion

#region Network Utilities
function Test-PortListening {
    <#
    .SYNOPSIS
        Check if a TCP port is listening
    .OUTPUTS
        Boolean - $true if port is open
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMs = $script:Config.PortCheckTimeout,
        [string]$HostAddress = "127.0.0.1"
    )

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($HostAddress, $Port, $null, $null)
        $success = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

        if ($success) {
            $client.EndConnect($asyncResult)
            $client.Close()
            return $true
        }

        $client.Close()
    }
    catch {
        # Connection failed
    }

    return $false
}

function Wait-PortListening {
    <#
    .SYNOPSIS
        Wait for a port to become available
    .OUTPUTS
        Boolean - $true if port became available within timeout
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMs = $script:Config.StartupTimeout
    )

    $startTime = Get-Date

    while (((Get-Date) - $startTime).TotalMilliseconds -lt $TimeoutMs) {
        if (Test-PortListening -Port $Port -TimeoutMs 350) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }

    return $false
}
#endregion

#region Process Management
function Test-CLIProxyAPIRunning {
    <#
    .SYNOPSIS
        Check whether CLIProxyAPI is currently running
    .OUTPUTS
        Boolean - $true if CLIProxyAPI is running
    #>
    return [bool](Get-Process -Name $script:Config.ProcessName -ErrorAction SilentlyContinue)
}

function Stop-CLIProxyAPI {
    <#
    .SYNOPSIS
        Stop the running CLIProxyAPI process
    #>
    try {
        Get-Process -Name $script:Config.ProcessName -ErrorAction SilentlyContinue |
            Stop-Process -Force
    }
    catch {
        Write-Verbose "No CLIProxyAPI process to stop"
    }

    Start-Sleep -Milliseconds 200
}
#endregion

#region GitHub Integration
function Get-LatestGitHubTag {
    <#
    .SYNOPSIS
        Get the latest release tag from a GitHub repository
    .PARAMETER Repository
        Repository in format "owner/repo"
    .OUTPUTS
        String - The latest tag name
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Repository
    )

    $headers = @{ "User-Agent" = $script:Config.AppName }
    $url = "https://api.github.com/repos/$Repository/releases/latest"

    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        return $response.tag_name
    }
    catch {
        throw "Failed to get latest tag from $Repository : $($_.Exception.Message)"
    }
}

function Get-GitHubAssetUrl {
    <#
    .SYNOPSIS
        Find download URL for a specific asset in latest release
    .OUTPUTS
        String - The browser download URL
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$AssetName
    )

    $headers = @{ "User-Agent" = $script:Config.AppName }
    $url = "https://api.github.com/repos/$Repository/releases/latest"

    try {
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1

        if (-not $asset) {
            throw "Asset not found: $AssetName"
        }

        return $asset.browser_download_url
    }
    catch {
        throw "Failed to get asset URL for $AssetName : $($_.Exception.Message)"
    }
}

function Invoke-PackageDownload {
    <#
    .SYNOPSIS
        Download CLIProxyAPI package with optional progress UI
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageUrl,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [bool]$ShowProgress = $true
    )

    if (-not $ShowProgress) {
        Show-BalloonTip "Downloading CLIProxyAPI..." -Icon Info -Duration 1200
        Invoke-WebRequest -Uri $PackageUrl -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
        return
    }

    # Create progress form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Downloading Updates"
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.Padding = New-Object System.Windows.Forms.Padding(18)
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $form.Controls.Add($layout)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Downloading CLIProxyAPI..."
    $label.Dock = "Fill"
    $label.TextAlign = "MiddleLeft"
    $layout.Controls.Add($label, 0, 0)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Dock = "Fill"
    $progressBar.Style = "Marquee"
    $progressBar.MarqueeAnimationSpeed = 30
    $layout.Controls.Add($progressBar, 0, 1)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.Text = ""
    $detailLabel.Dock = "Fill"
    $detailLabel.TextAlign = "TopLeft"
    $layout.Controls.Add($detailLabel, 0, 2)

    # Run download in background PowerShell instance
    $ps = [System.Management.Automation.PowerShell]::Create()
    [void]$ps.AddScript({
        param($Url, $Path)
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -ErrorAction Stop
    }).AddArgument($PackageUrl).AddArgument($OutputPath)

    $asyncHandle = $ps.BeginInvoke()

    # Poll timer - checks completion and shows downloaded size
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 300
    $pollTimer.Add_Tick({
        try {
            if (Test-Path -LiteralPath $OutputPath) {
                $sizeMb = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1MB, 1)
                $detailLabel.Text = "$sizeMb MB downloaded..."
            }
            if ($asyncHandle.IsCompleted) {
                $pollTimer.Stop()
                $form.Close()
            }
        }
        catch {}
    })
    $pollTimer.Start()

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $pollTimer.Stop()
    $pollTimer.Dispose()

    try {
        $ps.EndInvoke($asyncHandle) | Out-Null
        if ($ps.Streams.Error.Count -gt 0) {
            throw $ps.Streams.Error[0].Exception
        }
    }
    finally {
        $ps.Dispose()
    }
}
#endregion

#region Version Management
function Test-VersionInstalled {
    <#
    .SYNOPSIS
        Check if current version is installed, download if not
    .OUTPUTS
        Boolean - $true if version is ready to use
    #>
    param(
        [switch]$AssumeDownloadConsent
    )

    # Check if current version binaries exist
    if ($script:State.version) {
        $exePath = Get-CLIProxyAPIExecutablePath

        if ($exePath -and (Test-Path -LiteralPath $exePath)) {
            return $true
        }
    }

    # Need to download
    $arch = Get-SystemArchitecture

    try {
        $latestTag = Get-LatestGitHubTag -Repository $script:Config.Repository
        $version = $latestTag.TrimStart("v")

        $script:State.arch = $arch

        if (-not $AssumeDownloadConsent) {
            $message = @"
No version installed.

Latest:
CLIProxyAPI: $latestTag
Architecture: $arch

Download now?
"@

            $result = [System.Windows.Forms.MessageBox]::Show(
                $message,
                $script:Config.AppName,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )

            if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
                # User declined download, check if any old version exists
                if (Test-Path $script:Paths.VersionsDir) {
                    $existingVersions = Get-ChildItem -Path $script:Paths.VersionsDir -Directory |
                                        Where-Object {
                                            Test-Path -LiteralPath (Join-Path $_.FullName "cli-proxy-api.exe")
                                        } |
                                        Sort-Object Name -Descending |
                                        Select-Object -First 1

                    if ($existingVersions) {
                        # Use the latest existing version
                        $script:State.version = $existingVersions.Name
                        Export-State | Out-Null
                        Show-BalloonTip "Using existing version: $($existingVersions.Name)" -Icon Info -Duration 1500
                        return $true
                    }
                }
                return $false
            }
        }

        # Create directories
        New-Item -ItemType Directory -Path $script:Paths.VersionsDir -Force | Out-Null
        $versionDir = Join-Path $script:Paths.VersionsDir $latestTag
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null

        # Build asset names
        $zipName = "CLIProxyAPI_${version}_windows_${arch}.zip"

        # Create temp directory
        $tempDir = Join-Path $env:TEMP ("cliproxy_update_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $showProgress = Get-ShowUpdateProgressFromConfig

        try {
            # Get download URLs
            $downloadUrl = Get-GitHubAssetUrl -Repository $script:Config.Repository -AssetName $zipName

            $zipPath = Join-Path $tempDir $zipName

            # Download
            Invoke-PackageDownload -PackageUrl $downloadUrl -OutputPath $zipPath `
                                   -ShowProgress $showProgress

            # Extract
            $extractDir = Join-Path $tempDir "package"

            Show-BalloonTip "Extracting files..." -Icon Info -Duration 1200
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

            # Find executables
            $exeFile = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "cli-proxy-api.exe" |
                       Select-Object -First 1

            if (-not $exeFile) {
                $exeFile = Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter "*.exe" |
                       Select-Object -First 1
            }

            if (-not $exeFile) {
                throw "CLIProxyAPI executable not found in downloaded package"
            }

            # Stop running processes
            Stop-CLIProxyAPI

            # Copy to version directory
            Copy-Item -LiteralPath $exeFile.FullName -Destination (Join-Path $versionDir "cli-proxy-api.exe") -Force

            # Update state
            $script:State.version = $latestTag
            Export-State | Out-Null

            Show-BalloonTip "Installed $latestTag" -Icon Info -Duration 1500
            return $true
        }
        catch {
            Show-BalloonTip "Update failed: $($_.Exception.Message)" -Icon Error -Duration 2500
            return $false
        }
        finally {
            try {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
            catch {
                # Ignore cleanup errors
            }
        }
    }
    catch {
        Show-BalloonTip "Failed to check for updates: $($_.Exception.Message)" -Icon Error -Duration 2500
        return $false
    }
}

function Get-CLIProxyAPIExecutablePath {
    <#
    .SYNOPSIS
        Get executable path for the current CLIProxyAPI version
    .OUTPUTS
        String - Full path to executable, or $null if not found
    #>
    if (-not $script:State.version) {
        return $null
    }

    $versionDir = Join-Path $script:Paths.VersionsDir $script:State.version
    return (Join-Path $versionDir "cli-proxy-api.exe")
}
#endregion

#region Service Operations
function Start-CLIProxyAPI {
    <#
    .SYNOPSIS
        Start CLIProxyAPI
    #>
    # Ensure password is configured
    if (-not (Test-PasswordConfigured)) {
        Show-BalloonTip "Password not set. Start cancelled." -Icon Warning -Duration 2000
        return
    }

    # Ensure version is installed
    if (-not (Test-VersionInstalled)) {
        return
    }

    # Get executable path
    $exePath = Get-CLIProxyAPIExecutablePath

    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) {
        Show-BalloonTip "Executable not found for current version" -Icon Error -Duration 2500
        return
    }

    # Stop any running instance before starting a fresh one
    Stop-CLIProxyAPI

    # Build arguments
    $arguments = "--config `"$($script:Paths.Config)`""

    try {
        # Start process
        Start-Process -FilePath $exePath -ArgumentList $arguments -WindowStyle Hidden | Out-Null

        # Wait for port to become available
        $port = Get-PortFromConfig
        $portReady = Wait-PortListening -Port $port -TimeoutMs $script:Config.StartupTimeout

        # Update UI
        Update-TrayState

        if ($portReady) {
            Show-BalloonTip "Started CLIProxyAPI" -Icon Info -Duration 1200

            if ([bool]$script:State.autoOpenWebUI) {
                Start-Sleep -Seconds 1
                Open-WebUI
            }
        }
        else {
            Show-BalloonTip "Started, but port not ready yet" -Icon Warning -Duration 2500
        }
    }
    catch {
        Show-BalloonTip "Start failed: $($_.Exception.Message)" -Icon Error -Duration 2500
    }
}

function Restart-CLIProxyAPI {
    <#
    .SYNOPSIS
        Restart CLIProxyAPI
    #>
    Start-CLIProxyAPI
}

function Invoke-AutoUpdate {
    <#
    .SYNOPSIS
        Check for startup updates and install without confirmation when Auto Update is enabled.
    .OUTPUTS
        Boolean - $true if an update was installed
    #>
    try {
        $latestTag = Get-LatestGitHubTag -Repository $script:Config.Repository

        $currentExePath = Get-CLIProxyAPIExecutablePath
        if ($script:State.version -and
            ($script:State.version -eq $latestTag) -and
            $currentExePath -and
            (Test-Path -LiteralPath $currentExePath)) {
            return $false
        }

        $previousVersion = $script:State.version
        $previousArch = $script:State.arch

        Show-BalloonTip "Auto update found: $latestTag" -Icon Info -Duration 1500

        $script:State.version = $null
        $script:State.arch = Get-SystemArchitecture
        Export-State | Out-Null

        if (Test-VersionInstalled -AssumeDownloadConsent) {
            return $true
        }

        $script:State.version = $previousVersion
        $script:State.arch = $previousArch
        Export-State | Out-Null
        return $false
    }
    catch {
        Show-BalloonTip "Auto update check failed: $($_.Exception.Message)" -Icon Error -Duration 2500
        return $false
    }
}

function Invoke-Update {
    <#
    .SYNOPSIS
        Check for and install updates
    #>
    try {
        $latestTag = Get-LatestGitHubTag -Repository $script:Config.Repository

        # Check if already up to date
        $currentExePath = Get-CLIProxyAPIExecutablePath
        if ($script:State.version -and
            ($script:State.version -eq $latestTag) -and
            $currentExePath -and
            (Test-Path -LiteralPath $currentExePath)) {
            Show-BalloonTip "Already latest: $latestTag" -Icon Info -Duration 1500
            return
        }

        $previousVersion = $script:State.version
        $previousArch = $script:State.arch

        $message = @"
New version found:
CLIProxyAPI: $latestTag

Download and install?
"@

        $result = [System.Windows.Forms.MessageBox]::Show(
            $message,
            $script:Config.AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            Show-BalloonTip "Update cancelled" -Icon Info -Duration 1200
            return
        }

        # Clear version to force new install
        $script:State.version = $null
        $script:State.arch = Get-SystemArchitecture
        Export-State | Out-Null

        # Install new version
        if (Test-VersionInstalled -AssumeDownloadConsent) {
            Start-CLIProxyAPI
        }
        else {
            $script:State.version = $previousVersion
            $script:State.arch = $previousArch
            Export-State | Out-Null
        }
    }
    catch {
        Show-BalloonTip "Update check failed: $($_.Exception.Message)" -Icon Error -Duration 2500
    }
}
#endregion

#region UI Operations
function Show-BalloonTip {
    <#
    .SYNOPSIS
        Show a balloon tip notification
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet("None", "Info", "Warning", "Error")]
        [string]$Icon = "Info",

        [int]$Duration = $script:Config.BalloonTipDuration
    )

    $script:TrayIcon.ShowBalloonTip($Duration, $script:Config.AppName, $Message, $Icon)
}

function Open-WebUI {
    <#
    .SYNOPSIS
        Open the web management UI in default browser
    #>
    $port = Get-PortFromConfig

    if (-not (Test-PortListening -Port $port -TimeoutMs 500)) {
        Show-BalloonTip "Not running (port not listening)" -Icon Info -Duration 1500
        return
    }

    Start-Process "http://127.0.0.1:$port/management.html"
}

function Open-ApplicationFolder {
    <#
    .SYNOPSIS
        Open the application folder in Explorer
    #>
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($script:Paths.BaseDir)`""
}

function Open-ConfigFile {
    <#
    .SYNOPSIS
        Open config.yaml in the default editor.
    #>
    if (-not (Test-Path -LiteralPath $script:Paths.Config)) {
        Show-BalloonTip "config.yaml not found" -Icon Warning -Duration 1500
        return
    }

    Start-Process -FilePath $script:Paths.Config
}

function Open-ProjectPage {
    <#
    .SYNOPSIS
        Open the CLIProxyAPI Tray project page in the default browser.
    #>
    Start-Process $script:Config.ProjectUrl
}

function Update-TrayState {
    <#
    .SYNOPSIS
        Update tray icon and menu state based on service status
    #>
    $isRunning = Test-CLIProxyAPIRunning

    if ($script:MenuItems.AutoOpenWebUI) {
        $script:MenuItems.AutoOpenWebUI.Checked = [bool]$script:State.autoOpenWebUI
    }
    if ($script:MenuItems.AutoUpdate) {
        $script:MenuItems.AutoUpdate.Checked = [bool]$script:State.autoUpdate
    }

    if ($script:MenuItems.OpenConfig) {
        $script:MenuItems.OpenConfig.Enabled = Test-Path -LiteralPath $script:Paths.Config
    }

    # Update status display
    if ($isRunning) {
        $version = if ($script:State.version) { $script:State.version } else { "v?" }
        $script:MenuItems.CurrentStatus.Text = "Running ($version)"
        $script:TrayIcon.Text = "$($script:Config.AppName) - Running"

        if ($script:MenuItems.Start) {
            $script:MenuItems.Start.Enabled = $false
        }
        if ($script:MenuItems.OpenWebUI) {
            $script:MenuItems.OpenWebUI.Enabled = $true
        }
        $script:MenuItems.Restart.Enabled = $true
        $script:MenuItems.Stop.Enabled = $true
    }
    else {
        $script:MenuItems.CurrentStatus.Text = "Not Running"
        $script:TrayIcon.Text = $script:Config.AppName

        if ($script:MenuItems.Start) {
            $script:MenuItems.Start.Enabled = $true
        }
        if ($script:MenuItems.OpenWebUI) {
            $script:MenuItems.OpenWebUI.Enabled = $false
        }
        $script:MenuItems.Restart.Enabled = $false
        $script:MenuItems.Stop.Enabled = $false
    }
}
#endregion

#region Menu Construction
function New-TrayMenu {
    <#
    .SYNOPSIS
        Build the tray icon context menu
    #>
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Store menu items for later reference
    $script:MenuItems = @{}

    # Current status (disabled label)
    $script:MenuItems.CurrentStatus = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.CurrentStatus.Enabled = $false
    $script:MenuItems.CurrentStatus.Text = "Not Running"
    $menu.Items.Add($script:MenuItems.CurrentStatus) | Out-Null

    $menu.Items.Add("-") | Out-Null

    $script:MenuItems.Start = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Start.Text = "Start"
    $script:MenuItems.Start.Add_Click({ Start-CLIProxyAPI })
    $menu.Items.Add($script:MenuItems.Start) | Out-Null

    $script:MenuItems.Restart = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Restart.Text = "Restart"
    $script:MenuItems.Restart.Add_Click({ Restart-CLIProxyAPI })
    $menu.Items.Add($script:MenuItems.Restart) | Out-Null

    $script:MenuItems.Stop = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Stop.Text = "Stop"
    $script:MenuItems.Stop.Add_Click({
        Stop-CLIProxyAPI
        Update-TrayState
        Show-BalloonTip "Stopped" -Icon Info -Duration 1200
    })
    $menu.Items.Add($script:MenuItems.Stop) | Out-Null

    $menu.Items.Add("-") | Out-Null

    $openMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $openMenu.Text = "Open"

    $script:MenuItems.OpenWebUI = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.OpenWebUI.Text = "WebUI"
    $script:MenuItems.OpenWebUI.Add_Click({ Open-WebUI })
    $openMenu.DropDownItems.Add($script:MenuItems.OpenWebUI) | Out-Null

    $openFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openFolderItem.Text = "Folder"
    $openFolderItem.Add_Click({ Open-ApplicationFolder })
    $openMenu.DropDownItems.Add($openFolderItem) | Out-Null

    $script:MenuItems.OpenConfig = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.OpenConfig.Text = "Config"
    $script:MenuItems.OpenConfig.Add_Click({ Open-ConfigFile })
    $openMenu.DropDownItems.Add($script:MenuItems.OpenConfig) | Out-Null
    $menu.Items.Add($openMenu) | Out-Null

    $settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $settingsMenu.Text = "Settings"

    $script:MenuItems.AutoOpenWebUI = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.AutoOpenWebUI.Text = "Auto Open WebUI"
    $script:MenuItems.AutoOpenWebUI.Add_Click({
        $script:State.autoOpenWebUI = -not [bool]$script:State.autoOpenWebUI
        Export-State | Out-Null
        Update-TrayState
    })
    $settingsMenu.DropDownItems.Add($script:MenuItems.AutoOpenWebUI) | Out-Null

    $script:MenuItems.AutoUpdate = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.AutoUpdate.Text = "Auto Update"
    $script:MenuItems.AutoUpdate.Add_Click({
        $script:State.autoUpdate = -not [bool]$script:State.autoUpdate
        Export-State | Out-Null
        Update-TrayState
    })
    $settingsMenu.DropDownItems.Add($script:MenuItems.AutoUpdate) | Out-Null

    $resetPasswordItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $resetPasswordItem.Text = "Reset Password"
    $resetPasswordItem.Add_Click({
        if (-not (Test-ConfigExists)) {
            return
        }

        $newPassword = Request-Password -Title "Reset Password" -Prompt "Enter new password (secret-key):"

        if ([string]::IsNullOrWhiteSpace($newPassword)) {
            return
        }

        if (Set-SecretKeyInConfig $newPassword) {
            Show-BalloonTip "Password updated" -Icon Info -Duration 1200
        }
        else {
            Show-BalloonTip "Failed to update password" -Icon Error -Duration 2000
        }
    })
    $settingsMenu.DropDownItems.Add($resetPasswordItem) | Out-Null
    $menu.Items.Add($settingsMenu) | Out-Null

    $menu.Items.Add("-") | Out-Null

    $aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutItem.Text = "About"
    $aboutItem.Add_Click({ Open-ProjectPage })

    $script:MenuItems.Update = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:MenuItems.Update.Text = "Update"
    $script:MenuItems.Update.Add_Click({ Invoke-Update })

    $menu.Items.Add($script:MenuItems.Update) | Out-Null
    $menu.Items.Add($aboutItem) | Out-Null

    # Exit
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "Exit"
    $exitItem.Add_Click({
        Stop-CLIProxyAPI
        $script:UpdateTimer.Stop()
        $script:TrayIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $menu.Items.Add($exitItem) | Out-Null

    return $menu
}
#endregion

#region Entry Point
function Stop-TrayApplication {
    <#
    .SYNOPSIS
        Release tray application resources.
    #>
    try {
        if ($script:UpdateTimer) {
            $script:UpdateTimer.Stop()
            $script:UpdateTimer.Dispose()
        }
    }
    catch {
        Write-Verbose "Failed to dispose update timer"
    }

    try {
        if ($script:TrayIcon) {
            $script:TrayIcon.Visible = $false
            if ($script:TrayIcon.Icon) {
                $script:TrayIcon.Icon.Dispose()
            }
            $script:TrayIcon.Dispose()
        }
    }
    catch {
        Write-Verbose "Failed to dispose tray icon"
    }

    try {
        if ($script:AppMutex) {
            $script:AppMutex.ReleaseMutex()
            $script:AppMutex.Dispose()
        }
    }
    catch {
        Write-Verbose "Failed to release application mutex"
    }
}

try {
# Build and attach menu
$script:TrayIcon.ContextMenuStrip = New-TrayMenu

# Double-click tray icon handler
$script:TrayIcon.add_DoubleClick({
    if (Test-CLIProxyAPIRunning) {
        Open-WebUI
    }
    else {
        Start-CLIProxyAPI
    }
})

# Create periodic update timer
$script:UpdateTimer = New-Object System.Windows.Forms.Timer
$script:UpdateTimer.Interval = $script:Config.TimerInterval
$script:UpdateTimer.Add_Tick({ Update-TrayState })
$script:UpdateTimer.Start()

# Load saved state
Import-State

if (-not $script:State.arch) {
    $script:State.arch = Get-SystemArchitecture
    Export-State | Out-Null
}

# Ensure config exists
Test-ConfigExists | Out-Null

# Prompt for password if not set
Test-PasswordConfigured | Out-Null

# Update initial UI state
Update-TrayState

if ([bool]$script:State.autoUpdate) {
    Invoke-AutoUpdate | Out-Null
    Update-TrayState
}

# Auto-start behavior
if (Test-CLIProxyAPIRunning) {
    # Already running, just open WebUI
    if ($script:State.autoOpenWebUI) {
        Open-WebUI
    }
}
else {
    # Not running, ensure version and start
    if (Test-VersionInstalled) {
        Start-CLIProxyAPI
    }
    else {
        Update-TrayState
    }
}

# Run message loop
[System.Windows.Forms.Application]::Run()
}
finally {
    Stop-TrayApplication
}
#endregion
