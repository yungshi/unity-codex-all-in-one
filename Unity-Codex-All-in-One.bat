@echo off
setlocal
title Unity Codex All-in-One
chcp 65001 >nul
set "UNITY_CODEX_BUNDLE=%~f0"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command "try { $text = [IO.File]::ReadAllText($env:UNITY_CODEX_BUNDLE, [Text.Encoding]::UTF8); $marker = '#==UNITY_CODEX_POWERSHELL=='; $offset = $text.LastIndexOf($marker); if ($offset -lt 0) { throw 'Embedded script was not found.' }; & ([scriptblock]::Create($text.Substring($offset + $marker.Length))) } catch { Write-Host $_ -ForegroundColor Red; exit 1 }"
set "BUNDLE_EXIT_CODE=%ERRORLEVEL%"
if not "%BUNDLE_EXIT_CODE%"=="0" pause
exit /b %BUNDLE_EXIT_CODE%
#==UNITY_CODEX_POWERSHELL==
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:TranscriptStarted = $false
$script:UnityExe = $null
$script:CodexExe = $null
$script:BackupRoot = $null
$script:LastLog = $null
$script:UnityUntilReadySupported = $true
$script:UnityStage6Ui = $null
$script:UnityStage6Choice = ''
$script:UnityStage6Closing = $false

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[완료] $Text" -ForegroundColor Green
}

function Write-Notice {
    param([string]$Text)
    Write-Host "[안내] $Text" -ForegroundColor Yellow
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extraPaths = @(
        "$env:APPDATA\npm",
        "$env:USERPROFILE\.unity\bin",
        "$env:LOCALAPPDATA\Unity\UnityCLI\bin"
    )
    $env:Path = (@($machinePath, $userPath) + $extraPaths | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Resolve-NativeCommand {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }
    return $null
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Capture
    )
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorAction }
    $output | ForEach-Object { Write-Host $_ }
    if ($null -eq $exitCode) { throw "명령을 실행하지 못했습니다: $FilePath" }
    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "명령 실행 실패 (종료 코드 $exitCode): $FilePath $($Arguments -join ' ')"
    }
    if ($Capture) {
        return [PSCustomObject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
    }
    return $exitCode
}
function Select-UnityProject {
    param([string]$InitialPath)

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        return $InitialPath.Trim('"')
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Unity 프로젝트 폴더를 선택하세요 (Assets, Packages, ProjectSettings가 있는 폴더)'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    }
    catch {
        Write-Notice '폴더 선택창을 열 수 없어 경로를 직접 입력받습니다.'
    }

    return (Read-Host 'Unity 프로젝트 전체 경로를 입력하세요').Trim('"')
}

function Test-UnityProject {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    foreach ($required in @('Assets', 'Packages', 'ProjectSettings')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required) -PathType Container)) {
            return $false
        }
    }
    return $true
}

function Repair-UnityPackageJsonBom {
    param([string]$Path)

    $packagesPath = Join-Path $Path 'Packages'
    $backupRoot = $null
    $changed = 0
    $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)

    foreach ($name in @('manifest.json', 'packages-lock.json')) {
        $jsonPath = Join-Path $packagesPath $name
        if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { Write-Notice "$name 파일이 없어 건너뜁니다."; continue }

        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($jsonPath)
        $hasUtf8Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasUtf8Bom) { Write-Ok "$name : UTF-8 BOM 없음"; continue }

        [byte[]]$cleanBytes = [byte[]]::new($bytes.Length - 3)
        [System.Array]::Copy($bytes, 3, $cleanBytes, 0, $cleanBytes.Length)
        $cleanText = $utf8Strict.GetString($cleanBytes)
        $null = $cleanText | ConvertFrom-Json

        if (-not $backupRoot) {
            $backupRoot = Join-Path $env:TEMP ("Unity-JSON-BOM-Backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
        Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $backupRoot $name) -Force
        [System.IO.File]::WriteAllBytes($jsonPath, $cleanBytes)
        $changed++
        Write-Ok "$name UTF-8 BOM 자동 복구 완료"
    }

    if ($changed -eq 0) { Write-Notice '복구할 UTF-8 BOM이 없습니다.' }
    if ($changed -gt 0) {
        Write-Notice "복구 전 JSON 백업: $backupRoot"
    }
}

function Ensure-Winget {
    $winget = Resolve-NativeCommand @('winget.exe', 'winget')
    if (-not $winget) {
        throw 'winget을 찾을 수 없습니다. Microsoft Store에서 App Installer를 설치한 뒤 다시 실행하세요.'
    }
    return $winget
}

function Ensure-NodeAndNpm {
    Write-Section '1/7  Node.js와 npm 확인'
    Refresh-ProcessPath
    $npm = Resolve-NativeCommand @('npm.cmd', 'npm.exe', 'npm')

    if (-not $npm) {
        Write-Notice 'npm이 없어 Node.js LTS를 설치합니다.'
        $winget = Ensure-Winget
        Invoke-Native -FilePath $winget -Arguments @(
            'install', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--silent',
            '--accept-package-agreements', '--accept-source-agreements'
        ) | Out-Null
        Refresh-ProcessPath
        $npm = Resolve-NativeCommand @('npm.cmd', 'npm.exe', 'npm')
    }

    if (-not $npm) {
        throw 'Node.js 설치 후에도 npm을 찾지 못했습니다. PowerShell을 닫았다가 다시 열고 이 파일을 재실행하세요.'
    }

    Invoke-Native -FilePath $npm -Arguments @('--version') | Out-Null
    Write-Ok 'npm 사용 가능'
    return $npm
}

function Ensure-Codex {
    param([string]$NpmExe)
    Write-Section '2/7  OpenAI Codex CLI 설치 확인'
    Refresh-ProcessPath
    $codex = Resolve-NativeCommand @('codex.exe', 'codex.cmd', 'codex')

    if (-not $codex) {
        Write-Notice 'Codex CLI를 설치합니다.'
        Invoke-Native -FilePath $NpmExe -Arguments @('install', '-g', '@openai/codex@latest') | Out-Null
        Refresh-ProcessPath
        $codex = Resolve-NativeCommand @('codex.exe', 'codex.cmd', 'codex')
    }

    if (-not $codex) {
        throw 'Codex CLI 설치 후 codex 명령을 찾지 못했습니다. PowerShell을 닫았다가 다시 열고 재실행하세요.'
    }

    Invoke-Native -FilePath $codex -Arguments @('--version') | Out-Null
    Write-Ok 'Codex CLI 사용 가능'
    $script:CodexExe = $codex
}

function Ensure-UnityCli {
    Write-Section '3/7  Unity CLI 설치'
    Refresh-ProcessPath
    $unity = Resolve-NativeCommand @('unity.exe', 'unity')

    if (-not $unity) {
        Write-Notice 'Unity 공식 beta 채널 설치 스크립트로 Unity CLI를 설치합니다.'
        try {
            $env:UNITY_CLI_CHANNEL = 'beta'
            $installerUrl = 'https://public-cdn.cloud.unity3d.com/hub/prod/cli/install.ps1'
            $installer = Invoke-RestMethod -Uri $installerUrl -UseBasicParsing
            Invoke-Expression $installer
        }
        catch {
            Write-Notice '공식 설치 스크립트 실행에 실패해 winget 설치를 시도합니다.'
            $winget = Ensure-Winget
            Invoke-Native -FilePath $winget -Arguments @(
                'install', '--id', 'Unity.CLI', '--exact', '--silent',
                '--accept-package-agreements', '--accept-source-agreements'
            ) | Out-Null
        }
        Refresh-ProcessPath
        $unity = Resolve-NativeCommand @('unity.exe', 'unity')
    }

    if (-not $unity) {
        throw 'Unity CLI 설치 후 unity 명령을 찾지 못했습니다. PowerShell을 닫았다가 다시 열고 재실행하세요.'
    }

    Invoke-Native -FilePath $unity -Arguments @('--version') | Out-Null
    Write-Ok 'Unity CLI 사용 가능'
    $script:UnityExe = $unity
}

function Ensure-UnityLogin {
    Write-Section '4/7  Unity 계정 로그인 확인'
    $status = Invoke-Native -FilePath $script:UnityExe -Arguments @('auth', 'status') -AllowFailure -Capture
    if ($status.ExitCode -ne 0) {
        Write-Notice '브라우저가 열리면 Unity 계정으로 로그인하세요.'
        Invoke-Native -FilePath $script:UnityExe -Arguments @('auth', 'login') | Out-Null
    }
    Write-Ok 'Unity 계정 확인 완료'
}

function Ensure-CodexUnityPlugin {
    Write-Section '5/7  Unity 공식 Codex 플러그인 설치'

    Write-Notice 'Unity 공식 플러그인 마켓플레이스를 등록합니다.'
    $marketplaceResult = Invoke-Native -FilePath $script:CodexExe -Arguments @(
        'plugin', 'marketplace', 'add', 'Unity-Technologies/unity-agent-plugin'
    ) -AllowFailure -Capture

    Write-Notice 'Unity 공식 Codex 플러그인을 설치합니다.'
    $pluginResult = Invoke-Native -FilePath $script:CodexExe -Arguments @(
        'plugin', 'add', 'unity@unity-agent-plugin'
    ) -AllowFailure -Capture

    if (($pluginResult.ExitCode -eq 0) -or ($pluginResult.Output -match 'already|installed|enabled')) {
        Write-Ok 'Unity 공식 Codex 플러그인 설치/확인 완료'
        return
    }

    Write-Notice 'Codex 플러그인 서버가 응답하지 않아 플러그인 설치를 건너뜁니다.'
    Write-Notice '플러그인은 선택 사항이며 Pipeline, MCP, Unity CLI Skill 연동은 계속 진행합니다.'
    Write-Notice '서버가 정상화된 뒤 이 설치 파일을 다시 실행하면 플러그인 설치를 재시도합니다.'
}

function Invoke-NativeSafe {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )
    if (-not $FilePath) { return 127 }
    $previousErrorAction = $ErrorActionPreference
    $exitCode = 1
    try {
        $ErrorActionPreference = 'Continue'
        if ($Quiet) {
            & $FilePath @Arguments > $null 2>&1
        }
        else {
            & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        }
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Notice "외부 명령 오류를 건너뜁니다: $($_.Exception.Message)"
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return [int]$exitCode
}

function Backup-Path {
    param(
        [string]$Path,
        [string]$RelativeName
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $destination = Join-Path $script:BackupRoot $RelativeName
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $destination -Recurse -Force
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Remove-JsonDependency {
    param(
        [string]$JsonPath,
        [string]$DependencyName,
        [string]$BackupName
    )
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { return $false }
    $json = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
    if (-not $json.dependencies) { return $false }
    $property = $json.dependencies.PSObject.Properties[$DependencyName]
    if (-not $property) { return $false }

    Backup-Path -Path $JsonPath -RelativeName $BackupName
    $json.dependencies.PSObject.Properties.Remove($DependencyName)
    $newJson = $json | ConvertTo-Json -Depth 100
    Write-Utf8NoBom -Path $JsonPath -Text $newJson
    return $true
}

function Remove-UnityMcpFromConfig {
    param(
        [string]$ConfigPath,
        [string]$BackupName,
        [string]$DisplayName,
        [bool]$RemoveUnitySandboxRemainder = $false
    )
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $false }

    Backup-Path -Path $ConfigPath -RelativeName $BackupName
    $lines = @(Get-Content -LiteralPath $ConfigPath)
    $blocks = New-Object System.Collections.ArrayList
    $current = [PSCustomObject]@{ Header = $null; Lines = New-Object System.Collections.ArrayList }
    [void]$blocks.Add($current)

    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $current = [PSCustomObject]@{ Header = $Matches[1]; Lines = New-Object System.Collections.ArrayList }
            [void]$blocks.Add($current)
        }
        [void]$current.Lines.Add($line)
    }

    $targets = New-Object System.Collections.ArrayList
    foreach ($block in $blocks) {
        if (-not $block.Header) { continue }
        $body = ($block.Lines -join "`n")
        $isMcp = $block.Header -match '^mcp_servers\.'
        $isUnityCommand = $body -match '(?i)command\s*=\s*["''][^"'']*unity(?:\.exe)?["'']'
        $hasMcpArgument = $body -match '(?i)\bmcp\b'
        $looksLikeUnityName = $block.Header -match '(?i)unity'
        $isUnityHttpEndpoint = $body -match '(?i)https?://(?:127\.0\.0\.1|localhost):8080/mcp(?:[/?#"'']|$)'
        if ($isMcp -and ($looksLikeUnityName -or ($isUnityCommand -and $hasMcpArgument) -or $isUnityHttpEndpoint)) {
            [void]$targets.Add($block.Header)
        }
    }

    if ($targets.Count -eq 0) {
        Write-Notice "${DisplayName}에서 Unity MCP 항목을 찾지 못했습니다. 원본은 유지합니다."
        return $false
    }

    $keptLines = New-Object System.Collections.ArrayList
    foreach ($block in $blocks) {
        $removeBlock = $false
        foreach ($target in $targets) {
            if (($block.Header -eq $target) -or ($block.Header -like "$target.*")) {
                $removeBlock = $true
                break
            }
        }
        if (-not $removeBlock) {
            foreach ($line in $block.Lines) { [void]$keptLines.Add($line) }
        }
    }

    $meaningful = @($keptLines | Where-Object { $_ -notmatch '^\s*(#.*)?$' })
    $onlyUnitySandboxRemainder = $RemoveUnitySandboxRemainder -and (($meaningful -join "`n") -match '^\s*\[sandbox_workspace_write\]\s*\n\s*network_access\s*=\s*true\s*$')

    if (($meaningful.Count -eq 0) -or $onlyUnitySandboxRemainder) {
        Remove-Item -LiteralPath $ConfigPath -Force
        $configDirectory = Split-Path -Parent $ConfigPath
        if ((Test-Path -LiteralPath $configDirectory) -and -not (Get-ChildItem -LiteralPath $configDirectory -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $configDirectory -Force
        }
    }
    else {
        Write-Utf8NoBom -Path $ConfigPath -Text ($keptLines -join "`r`n")
    }
    return $true
}

function Remove-ProjectIntegration {
    param([string]$Path)
    Write-Section '1/4  프로젝트 Pipeline, MCP, Skill 제거'

    $manifestPath = Join-Path $Path 'Packages\manifest.json'
    $lockPath = Join-Path $Path 'Packages\packages-lock.json'
    $removedManifest = Remove-JsonDependency -JsonPath $manifestPath -DependencyName 'com.unity.pipeline' -BackupName 'Packages\manifest.json'
    $removedLock = Remove-JsonDependency -JsonPath $lockPath -DependencyName 'com.unity.pipeline' -BackupName 'Packages\packages-lock.json'
    if ($removedManifest -or $removedLock) { Write-Ok 'com.unity.pipeline 참조 제거 완료' }
    else { Write-Notice 'com.unity.pipeline 참조가 없었습니다.' }

    foreach ($relative in @('.agents\skills\unity-cli', '.agents\skills\unity-pipeline')) {
        $target = Join-Path $Path $relative
        if (Test-Path -LiteralPath $target) {
            Assert-ContainedRemoval -Path $target -Root $Path
            Backup-Path -Path $target -RelativeName $relative
            Remove-Item -LiteralPath $target -Recurse -Force
            Write-Ok "$relative 제거 완료"
        }
    }

    $packageCache = Join-Path $Path 'Library\PackageCache'
    if (Test-Path -LiteralPath $packageCache -PathType Container) {
        $cacheItems = @(Get-ChildItem -LiteralPath $packageCache -Directory -Filter 'com.unity.pipeline@*' -ErrorAction SilentlyContinue)
        foreach ($item in $cacheItems) {
            Assert-ContainedRemoval -Path $item.FullName -Root $Path
            if ($item.FullName.StartsWith($packageCache, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force
            }
        }
    }

    $configPath = Join-Path $Path '.codex\config.toml'
    if (Remove-UnityMcpFromConfig -ConfigPath $configPath -BackupName 'project-config\config.toml' -DisplayName '프로젝트 config.toml' -RemoveUnitySandboxRemainder $true) {
        Write-Ok '프로젝트 로컬 Unity MCP 설정 제거 완료'
    }

    $userConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (Remove-UnityMcpFromConfig -ConfigPath $userConfigPath -BackupName 'user-config\config.toml' -DisplayName '사용자 전역 config.toml') {
        Write-Ok '사용자 전역 Unity MCP 설정 제거 완료'
    }
}

function Remove-CodexPlugin {
    Write-Section '2/4  Unity Codex 플러그인 제거'
    Refresh-ProcessPath
    $codex = Resolve-NativeCommand @('codex.exe', 'codex.cmd', 'codex')
    if (-not $codex) {
        Write-Notice 'codex 명령이 없어 플러그인 제거를 건너뜁니다.'
        return
    }

    $result = Invoke-NativeSafe -FilePath $codex -Arguments @('plugin', 'remove', 'unity@unity-agent-plugin')
    if ($result -ne 0) {
        Write-Notice 'Unity Codex 플러그인이 없거나 제거 명령을 지원하지 않습니다. 다음 단계로 계속합니다.'
    }
    [void](Invoke-NativeSafe -FilePath $codex -Arguments @('plugin', 'marketplace', 'remove', 'unity-agent-plugin'))
    Write-Ok 'Unity Codex 플러그인 제거 명령 완료'
}

function Remove-CodexAndUnityCli {
    Write-Section '3/4  Codex CLI와 Unity CLI 제거'
    Refresh-ProcessPath

    $npm = Resolve-NativeCommand @('npm.cmd', 'npm.exe', 'npm')
    if ($npm) {
        [void](Invoke-NativeSafe -FilePath $npm -Arguments @('uninstall', '-g', '@openai/codex'))
        Write-Ok 'npm Codex CLI 제거 명령 완료'
    }
    else {
        Write-Notice 'npm을 찾지 못해 Codex CLI 자동 제거를 건너뜁니다.'
    }

    $unity = Resolve-NativeCommand @('unity.exe', 'unity')
    if ($unity) {
        [void](Invoke-NativeSafe -FilePath $unity -Arguments @('self-uninstall', '-y'))
        Write-Ok 'Unity CLI self-uninstall 명령 완료'
    }

    Refresh-ProcessPath
    $unityAfter = Resolve-NativeCommand @('unity.exe', 'unity')
    $winget = Resolve-NativeCommand @('winget.exe', 'winget')
    if ($unityAfter -and $winget) {
        Write-Notice '남아 있는 Unity CLI winget 패키지를 확인합니다.'
        $wingetUnityResult = Invoke-NativeSafe -FilePath $winget -Arguments @(
            'uninstall', '--id', 'Unity.CLI', '--exact', '--silent', '--accept-source-agreements'
        ) -Quiet
        if ($wingetUnityResult -eq 0) {
            Write-Ok 'winget Unity CLI 제거 완료'
        }
        else {
            Write-Notice '제거할 winget Unity CLI 패키지가 없었습니다.'
        }
    }
}

function Remove-NodeJs {
    Write-Section '4/4  Node.js 제거'
    $winget = Resolve-NativeCommand @('winget.exe', 'winget')
    if (-not $winget) {
        Write-Notice 'winget을 찾지 못해 Node.js 제거를 건너뜁니다.'
        return
    }
    Write-Notice 'winget으로 Node.js LTS를 제거합니다.'
    $nodeResult = Invoke-NativeSafe -FilePath $winget -Arguments @(
        'uninstall', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--silent', '--accept-source-agreements'
    ) -Quiet
    if ($nodeResult -eq 0) {
        Write-Ok 'winget Node.js LTS 제거 완료'
    }
    else {
        Write-Notice '제거할 winget Node.js LTS 패키지가 없거나 자동 제거하지 못했습니다.'
    }
}

function Assert-ContainedRemoval {
    param([string]$Path, [string]$Root)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $targetPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $targetPath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "프로젝트 범위를 벗어난 삭제 경로입니다: $targetPath"
    }
    $current = $targetPath
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "연결된 폴더는 자동 삭제하지 않습니다: $current"
        }
        if ($current -eq $rootPath) { break }
        $current = Split-Path -Parent $current
    }
    $links = @(Get-ChildItem -LiteralPath $targetPath -Recurse -Force | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ($links.Count -gt 0) { throw "삭제 대상에 연결된 파일/폴더가 있습니다: $targetPath" }
}

function Get-HubPathValues {
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 12) { return }
    if ($Value -is [string]) {
        if ($Value -match '^(?:[A-Za-z]:[\\/]|\\\\)') { $Value }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in $Value) { Get-HubPathValues -Value $entry -Depth ($Depth + 1) }
        return
    }
    if ($Value -is [PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '^(?:[A-Za-z]:[\\/]|\\\\)') { $property.Name }
            Get-HubPathValues -Value $property.Value -Depth ($Depth + 1)
        }
    }
}

function Get-ProjectSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Get-Location).Path)
    if ($env:UNITY_CODEX_BUNDLE) { $roots.Add((Split-Path -Parent $env:UNITY_CODEX_BUNDLE)) }
    foreach ($special in @('MyDocuments', 'Desktop')) {
        $path = [Environment]::GetFolderPath($special)
        if ($path) { $roots.Add($path) }
    }
    foreach ($relative in @('Downloads', 'source\repos', 'Unity', 'UnityProjects', 'Projects')) {
        $roots.Add((Join-Path $env:USERPROFILE $relative))
    }
    $driveRoots = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed
    } | ForEach-Object { $_.RootDirectory.FullName })
    foreach ($driveRoot in $driveRoots) {
        foreach ($relative in @('unity', 'UnityProjects', 'UnityProject', 'Projects', 'Dev', 'Games', 'source\repos')) {
            $roots.Add((Join-Path $driveRoot $relative))
        }
    }
    foreach ($driveRoot in $driveRoots) { $roots.Add($driveRoot) }
    return $roots.ToArray()
}

function Find-UnityProjects {
    param(
        [string[]]$RootPaths = @(),
        [string[]]$HubFiles = @(),
        [int]$MaxDepth = 5,
        [int]$MaxDirectories = 8000,
        [int]$MaxSeconds = 12
    )
    # Passing explicit roots isolates a custom scan from the user's Hub records.
    $useDefaultRoots = $RootPaths.Count -eq 0
    if ($useDefaultRoots) {
        $RootPaths = @(Get-ProjectSearchRoots)
        if ($HubFiles.Count -eq 0) {
            $hubRoot = Join-Path $env:APPDATA 'UnityHub'
            $HubFiles = @('projects-v1.json', 'projects.json', 'projectDir.json' | ForEach-Object { Join-Path $hubRoot $_ })
        }
    }
    $found = @{}
    $visited = @{}
    $queue = New-Object System.Collections.Generic.Queue[object]
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastNotice = 0
    $scanned = 0
    $limitReached = $false
    $excluded = @('Library', 'Temp', 'Logs', 'obj', 'bin', 'Build', 'Builds',
        'node_modules', '.git', '.svn', '.hg', '.codex', '.agents', '.cache',
        'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
        'AppData', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'Windows.old')

    function Add-DiscoveredProject {
        param([string]$Path, [string]$Source)
        if (-not (Test-UnityProject -Path $Path)) { return }
        $fullPath = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
        if ($found.ContainsKey($fullPath)) { return }
        $version = '버전 정보 없음'
        $versionFile = Join-Path $fullPath 'ProjectSettings\ProjectVersion.txt'
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            try {
                $versionText = [System.IO.File]::ReadAllText($versionFile)
                if ($versionText -match '(?m)^m_EditorVersion:\s*([^\r\n]+)') { $version = $Matches[1].Trim() }
            } catch { }
        }
        $found[$fullPath] = [PSCustomObject]@{
            Name = Split-Path -Leaf $fullPath; Path = $fullPath; Version = $version; Source = $Source
        }
    }

    foreach ($hubFile in $HubFiles) {
        if (-not (Test-Path -LiteralPath $hubFile -PathType Leaf)) { continue }
        try {
            $hubData = [System.IO.File]::ReadAllText($hubFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($hubPath in @(Get-HubPathValues -Value $hubData | Select-Object -Unique)) {
                if ($hubPath.StartsWith('\\')) { continue }
                if (-not (Test-Path -LiteralPath $hubPath -PathType Container)) { continue }
                Add-DiscoveredProject -Path $hubPath -Source 'Unity Hub'
                $queue.Enqueue([PSCustomObject]@{ Path = $hubPath; Depth = 0 })
            }
        } catch { Write-Notice '일부 Unity Hub 기록을 읽지 못해 폴더 탐색을 계속합니다.' }
    }
    foreach ($root in $RootPaths) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            $queue.Enqueue([PSCustomObject]@{ Path = $root; Depth = 0 })
        }
    }
    while ($queue.Count -gt 0) {
        if ($scanned -ge $MaxDirectories -or $clock.Elapsed.TotalSeconds -ge $MaxSeconds) {
            $limitReached = $true
            break
        }
        $entry = $queue.Dequeue()
        try {
            $directory = Get-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
            $fullPath = $directory.FullName
            if ($visited.ContainsKey($fullPath)) { continue }
            $visited[$fullPath] = $true
            # Do not traverse junctions/symlinks or remote shares during disk scans.
            if ($fullPath.StartsWith('\\') -or ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $scanned++
            Add-DiscoveredProject -Path $fullPath -Source '폴더 탐색'
            if ($found.ContainsKey($fullPath.TrimEnd('\'))) { continue }
            if ($entry.Depth -ge $MaxDepth) { $limitReached = $true; continue }
            foreach ($child in @(Get-ChildItem -LiteralPath $fullPath -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($child.Name -in $excluded) { continue }
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $queue.Enqueue([PSCustomObject]@{ Path = $child.FullName; Depth = $entry.Depth + 1 })
            }
        } catch { continue }
        if ($clock.Elapsed.TotalSeconds - $lastNotice -ge 3) {
            Write-Host "  탐색 중: $scanned 개 폴더 확인 / $($found.Count) 개 프로젝트 발견" -ForegroundColor DarkGray
            $lastNotice = $clock.Elapsed.TotalSeconds
        }
    }
    $clock.Stop()
    return [PSCustomObject]@{
        Projects = @($found.Values | Sort-Object Path)
        ScannedDirectories = $scanned
        LimitReached = $limitReached
    }
}

function Get-SelectedProject {
    Write-Section 'Unity 프로젝트 자동 탐색'
    Write-Host 'Unity Hub 기록과 일반 프로젝트 폴더, 로컬 드라이브를 탐색합니다.'
    Write-Host '기본 탐색은 약 12초 이내입니다. 권한이 없는 폴더는 건너뜁니다.'
    $result = Find-UnityProjects
    while ($true) {
        $projects = @($result.Projects)
        Write-Host ''
        if ($projects.Count -eq 0) { Write-Notice '탐색 범위에서 Unity 프로젝트를 찾지 못했습니다.' }
        else {
            for ($index = 0; $index -lt $projects.Count; $index++) {
                $item = $projects[$index]
                Write-Host ("  {0}. {1}  |  Unity {2}  |  {3}" -f ($index + 1), $item.Name, $item.Version, $item.Source) -ForegroundColor Cyan
                Write-Host "     $($item.Path)"
            }
        }
        if ($result.LimitReached) { Write-Notice '탐색 범위 제한이 적용됐습니다. 필요하면 추가 탐색이나 직접 선택을 사용하세요.' }
        Write-Host '  A. 로컬 드라이브 추가 탐색 (깊이 10단계 / 약 30초)'
        Write-Host '  M. 폴더 직접 선택'
        Write-Host '  0. 취소'
        $choice = (Read-Host '프로젝트 번호 또는 A/M/0을 입력하세요').Trim()
        if ($choice -eq '0') { return $null }
        if ($choice -ieq 'A') {
            Write-Notice '추가 탐색을 시작합니다.'
            $deeper = Find-UnityProjects -MaxDepth 10 -MaxDirectories 40000 -MaxSeconds 30
            $merged = @{}
            foreach ($item in @($projects) + @($deeper.Projects)) { $merged[$item.Path] = $item }
            $result = [PSCustomObject]@{ Projects = @($merged.Values | Sort-Object Path); LimitReached = $deeper.LimitReached }
            continue
        }
        $project = $null
        if ($choice -ieq 'M') {
            $project = Select-UnityProject -InitialPath ''
            if ([string]::IsNullOrWhiteSpace($project)) { continue }
        }
        else {
            $number = 0
            if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $projects.Count) {
                Write-Notice '목록의 프로젝트 번호 또는 A/M/0을 입력하세요.'
                continue
            }
            $project = $projects[$number - 1].Path
        }
        if (-not (Test-UnityProject -Path $project)) {
            Write-Notice '현재 유효한 Unity 프로젝트가 아닙니다. 다시 선택하세요.'
            continue
        }
        return (Resolve-Path -LiteralPath $project).Path
    }
}

function Start-BundleLog {
    param([string]$Path)
    $script:LastLog = $Path
    try {
        Start-Transcript -Path $Path -Force | Out-Null
        $script:TranscriptStarted = $true
    }
    catch { Write-Notice '로그를 시작하지 못했습니다. 화면의 실행 결과를 확인하세요.' }
}

function Stop-BundleLog {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:TranscriptStarted = $false
    }
}

function ConvertTo-UnityProjectKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [System.IO.Path]::GetFullPath($Path.Replace('/', '\')).TrimEnd('\').ToLowerInvariant() }
    catch { return '' }
}

function Test-UnityProjectProcess {
    param([string]$Path)
    $key = ConvertTo-UnityProjectKey $Path
    if (-not $key) { return $false }
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'Unity.exe'" -ErrorAction Stop)) {
            if ($process.CommandLine -match '(?i)(?:^|\s)-projectPath(?:\s+|=)(?:"([^"]+)"|([^\s]+))') {
                $processPath = $Matches[1]
                if (-not $processPath) { $processPath = $Matches[2] }
                if ((ConvertTo-UnityProjectKey $processPath) -eq $key) { return $true }
            }
        }
    } catch { }
    return $false
}

function Test-UnityReadyJson {
    param([string]$Text, [string]$Path, [int]$ExitCode = 0)
    if ($ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($Text)) { return $false }
    try {
        $envelope = $Text | ConvertFrom-Json
        if ($envelope.PSObject.Properties['success'].Value -ne $true) { return $false }
        $data = $envelope.PSObject.Properties['data'].Value
        $instances = $data.PSObject.Properties['instances'].Value
        $key = ConvertTo-UnityProjectKey $Path
        if (-not $key) { return $false }
        foreach ($instance in @($instances)) {
            $state = $instance.PSObject.Properties['state'].Value
            $project = $instance.PSObject.Properties['project'].Value
            if ($state -eq 'ready' -and (ConvertTo-UnityProjectKey $project) -eq $key) { return $true }
        }
    } catch { }
    return $false
}

function Show-UnityStatusAdvice {
    param([string]$Text)
    try {
        $envelope = $Text | ConvertFrom-Json
        foreach ($propertyName in @('errors', 'warnings', 'notifications')) {
            $property = $envelope.PSObject.Properties[$propertyName]
            if ($null -eq $property) { continue }
            foreach ($item in @($property.Value)) {
                $message = $item.PSObject.Properties['message']
                if ($null -ne $message -and $message.Value) { Write-Notice ([string]$message.Value) }
            }
        }
    } catch { }
}

function Read-UnityWaitHotkey {
    if ($null -ne $script:UnityStage6Ui) {
        try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    }
    if ($script:UnityStage6Choice) {
        $choice = $script:UnityStage6Choice
        $script:UnityStage6Choice = ''
        return $choice
    }
    try {
        if ([Console]::IsInputRedirected) { return '' }
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true).KeyChar
            if ($key -eq 'm' -or $key -eq 'M') { return 'M' }
            if ($key -eq '0') { return '0' }
            if ($key -eq 'a' -or $key -eq 'A') { return 'A' }
        }
    } catch { }
    return ''
}

function ConvertTo-WindowsNativeArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Open-UnityStage6Window {
    param([string]$Path, [bool]$ShowWindow = $true)
    $script:UnityStage6Choice = ''
    $script:UnityStage6Closing = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text = '6/7 Unity 실행 확인'
        $form.ClientSize = New-Object System.Drawing.Size(610, 225)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)
        $description = New-Object System.Windows.Forms.Label
        $description.Location = New-Object System.Drawing.Point(15, 12)
        $description.Size = New-Object System.Drawing.Size(580, 68)
        $description.Text = "Unity가 열렸고 패키지 설치/컴파일이 끝났는데 진행되지 않으면`r`n아래 계속 진행 버튼을 누르세요.`r`n프로젝트: $Path"
        $status = New-Object System.Windows.Forms.Label
        $status.Location = New-Object System.Drawing.Point(15, 88)
        $status.Size = New-Object System.Drawing.Size(580, 38)
        $status.Text = 'Unity 열기 명령을 기다리는 중입니다.'
        $manual = New-Object System.Windows.Forms.Button
        $manual.Location = New-Object System.Drawing.Point(15, 137)
        $manual.Size = New-Object System.Drawing.Size(405, 55)
        $manual.Text = 'Unity 열렸음 · 계속 진행 (M)'
        $manual.Add_Click({ $script:UnityStage6Choice = 'M' })
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Location = New-Object System.Drawing.Point(435, 137)
        $cancel.Size = New-Object System.Drawing.Size(160, 55)
        $cancel.Text = '취소 (0)'
        $cancel.Add_Click({ $script:UnityStage6Choice = '0' })
        $form.Controls.AddRange(@($description, $status, $manual, $cancel))
        $form.KeyPreview = $true
        $form.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::M) { $script:UnityStage6Choice = 'M' }
            if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::D0 -or $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:UnityStage6Choice = '0' }
        })
        $form.Add_FormClosing({
            if (-not $script:UnityStage6Closing) { $script:UnityStage6Choice = '0' }
        })
        $script:UnityStage6Ui = [PSCustomObject]@{ Form = $form; Status = $status; ManualButton = $manual; CancelButton = $cancel }
        if ($ShowWindow) { $form.Show(); [System.Windows.Forms.Application]::DoEvents() }
    }
    catch {
        $script:UnityStage6Ui = $null
        Write-Notice '버튼 창을 열지 못했습니다. CMD 창에서 M 키로 수동 진행할 수 있습니다.'
    }
}

function Set-UnityStage6Status {
    param([string]$Text)
    if ($null -ne $script:UnityStage6Ui) {
        try { $script:UnityStage6Ui.Status.Text = $Text; [System.Windows.Forms.Application]::DoEvents() } catch { }
    }
}

function Close-UnityStage6Window {
    $script:UnityStage6Closing = $true
    if ($null -ne $script:UnityStage6Ui) {
        try { $script:UnityStage6Ui.Form.Close(); $script:UnityStage6Ui.Form.Dispose() } catch { }
    }
    $script:UnityStage6Ui = $null
    $script:UnityStage6Choice = ''
}

function Invoke-UnityStage6Command {
    param([string]$Path, [string[]]$Arguments, [int]$WaitSeconds = 30, [string]$StageLabel = 'Unity 열기')
    Write-Host 'Unity가 열렸는데 멈춰 있으면 버튼을 클릭하거나 CMD 창에서 M을 누르세요.' -ForegroundColor Yellow
    Set-UnityStage6Status "$StageLabel 명령 대기 중 — Unity 준비가 끝났으면 계속 진행 버튼을 누르세요."
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:UnityExe
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-WindowsNativeArgument $_ }) -join ' '
    $info.WorkingDirectory = $Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # Do not capture streams here: an Editor launched by the CLI may inherit
    # those handles and keep ReadToEnd waiting until the Editor closes.
    $info.EnvironmentVariables['UNITY_NO_CONSENT_PROMPT'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $result = [PSCustomObject]@{ Choice = ''; ExitCode = 127; ProcessId = 0 }
    try {
        [void]$process.Start()
        $result.ProcessId = $process.Id
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $choice = Read-UnityWaitHotkey
            if ($choice) { $result.Choice = $choice; return $result }
            if ($process.HasExited) { $result.ExitCode = $process.ExitCode; return $result }
            if ($WaitSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -ge $WaitSeconds) {
                Write-Notice 'Unity 열기 명령의 대기를 끝내고 실행 상태 확인으로 넘어갑니다.'
                return $result
            }
            Start-Sleep -Milliseconds 100
        }
    }
    catch { Write-Notice "$StageLabel 명령을 실행하지 못했습니다: $($_.Exception.Message)"; return $result }
    finally {
        # Detach the launcher on manual continue or timeout. Never terminate the
        # launcher or its Editor; Unity remains open for the following steps.
        $process.Dispose()
    }
}

function Invoke-UnityOpenWithManualContinue {
    param([string]$Path, [int]$WaitSeconds = 30)
    return (Invoke-UnityStage6Command -Path $Path -Arguments @('open', $Path, '--non-interactive') -WaitSeconds $WaitSeconds -StageLabel 'Unity 열기')
}

function Invoke-UnityStatusProbe {
    param([string]$Path, [bool]$UntilReady, [int]$TimeoutSeconds = 20)
    $arguments = @('status', '--project-path', $Path, '--format', 'json', '--no-banner', '--non-interactive')
    if ($UntilReady) { $arguments += @('--until-ready', '--timeout', [string]$TimeoutSeconds) }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:UnityExe
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-WindowsNativeArgument $_ }) -join ' '
    $info.WorkingDirectory = $Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $info.EnvironmentVariables['UNITY_NO_CONSENT_PROMPT'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $result = [PSCustomObject]@{ Text = ''; ErrorText = ''; ExitCode = 127; Choice = '' }
    try {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $hardTimeout = 8
        if ($UntilReady) { $hardTimeout = $TimeoutSeconds + 5 }
        while (-not $process.HasExited) {
            $choice = Read-UnityWaitHotkey
            if ($choice) { $result.Choice = $choice; return $result }
            if ($clock.Elapsed.TotalSeconds -gt $hardTimeout) {
                $result.ErrorText = '상태 확인 명령이 응답하지 않았습니다.'
                return $result
            }
            Start-Sleep -Milliseconds 100
        }
        $result.Text = $outTask.GetAwaiter().GetResult()
        $result.ErrorText = $errTask.GetAwaiter().GetResult()
        $result.ExitCode = $process.ExitCode
        return $result
    }
    catch { $result.ErrorText = $_.Exception.Message; return $result }
    finally {
        # Only stop this read-only CLI probe; never stop any Unity Editor.
        try {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1000) }
        } catch { }
        $process.Dispose()
    }
}

function Wait-UnityProjectReady {
    param([string]$Path, [int]$WaitSeconds = 20)
    Write-Section 'Unity 실행 / 연결 준비 자동 확인'
    Write-Host "대상 프로젝트: $Path" -ForegroundColor Cyan
    Write-Host '선택한 프로젝트의 Editor가 ready 상태가 되면 자동으로 계속합니다.'
    Write-Host 'Unity 창으로 전환하고 컴파일/패키지 설치가 끝났는지 확인하세요.'
    Write-Host '대기 중 M: Unity가 열렸고 컴파일도 끝났다고 수동 확인 / 0: 취소' -ForegroundColor Yellow
    Set-UnityStage6Status 'Unity 연결 준비 자동 확인 중 — 자동 확인이 안 되면 계속 진행 버튼을 누르세요.'
    while ($true) {
        if (Test-UnityProjectProcess -Path $Path) {
            Write-Ok '선택한 프로젝트의 Unity 실행을 감지했습니다. 연결 준비 상태를 확인합니다.'
        }
        else { Write-Notice '선택한 프로젝트의 실행을 아직 확인하지 못했습니다. 자동 확인을 시작합니다.' }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $lastResult = $null
        while ($clock.Elapsed.TotalSeconds -lt $WaitSeconds) {
            $remaining = [math]::Max(1, [int][math]::Ceiling($WaitSeconds - $clock.Elapsed.TotalSeconds))
            $lastResult = Invoke-UnityStatusProbe -Path $Path -UntilReady $script:UnityUntilReadySupported -TimeoutSeconds $remaining
            if ($lastResult.Choice -eq 'M') { Write-Notice '수동 확인으로 계속합니다. 자동 연결 확인은 생략했습니다.'; return $true }
            if ($lastResult.Choice -eq '0') { Write-Notice '연동을 취소했습니다.'; return $false }
            if ($lastResult.Choice -eq 'A') { continue }
            if (Test-UnityReadyJson -Text $lastResult.Text -Path $Path -ExitCode $lastResult.ExitCode) {
                Show-UnityStatusAdvice -Text $lastResult.Text
                Write-Ok '선택한 프로젝트의 Unity Editor 연결 준비 완료를 자동 확인했습니다.'
                return $true
            }
            if ($script:UnityUntilReadySupported -and (($lastResult.Text + $lastResult.ErrorText) -match '(?i)unknown option.*until-ready|unknown option.*timeout')) {
                $script:UnityUntilReadySupported = $false
                Write-Notice '이 CLI 버전은 자동 대기 옵션을 지원하지 않아 반복 상태 확인을 사용합니다.'
                continue
            }
            if ($script:UnityUntilReadySupported) { break }
            $pauseClock = [System.Diagnostics.Stopwatch]::StartNew()
            while ($pauseClock.Elapsed.TotalSeconds -lt 2 -and $clock.Elapsed.TotalSeconds -lt $WaitSeconds) {
                $choice = Read-UnityWaitHotkey
                if ($choice -eq 'M') { Write-Notice '수동 확인으로 계속합니다. 자동 연결 확인은 생략했습니다.'; return $true }
                if ($choice -eq '0') { Write-Notice '연동을 취소했습니다.'; return $false }
                Start-Sleep -Milliseconds 100
            }
        }
        Write-Notice '자동으로 연결 준비 상태를 확인하지 못했습니다.'
        if ($null -ne $lastResult) { Show-UnityStatusAdvice -Text $lastResult.Text }
        Write-Host '  A. 자동 확인 다시 시도'
        Write-Host '  M. Unity가 열렸고 컴파일도 끝났음 — 수동 확인하고 계속'
        Write-Host '  0. 취소하고 메뉴로 돌아가기'
        while ($true) {
            if ($null -ne $script:UnityStage6Ui -and -not [Console]::IsInputRedirected) {
                Set-UnityStage6Status '자동 확인이 안 됐습니다. 준비가 끝났으면 계속 진행 버튼을 누르세요. CMD 창 A 키로 재시도할 수 있습니다.'
                $choice = Read-UnityWaitHotkey
                if (-not $choice) { Start-Sleep -Milliseconds 100; continue }
            }
            else { $choice = (Read-Host 'A/M/0을 입력하세요').Trim() }
            if ($choice -ieq 'M') { Write-Notice '수동 확인으로 계속합니다. 자동 연결 확인은 생략했습니다.'; return $true }
            if ($choice -eq '0') { Write-Notice '연동을 취소했습니다.'; return $false }
            if ($choice -ieq 'A') { break }
            Write-Notice 'A/M/0 중에서 선택하세요.'
        }
    }
}

function Ensure-PipelineAndLink {
    param([string]$Path)
    Write-Section '6/7  Unity Pipeline 설치 및 Codex MCP 연동'
    Push-Location -LiteralPath $Path
    try {
        Open-UnityStage6Window -Path $Path
        Write-Notice '프로젝트에 com.unity.pipeline 패키지를 먼저 설치합니다.'
        $pipelineResult = Invoke-UnityStage6Command -Path $Path -Arguments @('pipeline', 'install', '--project-path', $Path, '--non-interactive') -WaitSeconds 0 -StageLabel 'Pipeline 설치'
        if ($pipelineResult.Choice -eq '0') { Write-Notice '연동을 취소했습니다.'; return $false }
        $manualConfirmed = $pipelineResult.Choice -eq 'M'
        if (-not $manualConfirmed) {
            if ($pipelineResult.ExitCode -ne 0) { throw "Pipeline 설치 명령이 실패했습니다 (종료 코드 $($pipelineResult.ExitCode))." }
            Write-Notice 'Unity 프로젝트를 엽니다. 이미 열려 있으면 기존 창을 사용합니다.'
            $openResult = Invoke-UnityOpenWithManualContinue -Path $Path
            if ($openResult.Choice -eq '0') { Write-Notice '연동을 취소했습니다.'; return $false }
            $manualConfirmed = $openResult.Choice -eq 'M'
        }
        if ($manualConfirmed) {
            Write-Notice 'Unity가 준비됐다는 수동 확인으로 명령 대기와 자동 확인을 건너뛰고 MCP 설정으로 진행합니다.'
        }
        elseif (-not (Wait-UnityProjectReady -Path $Path)) { return $false }
        Close-UnityStage6Window
        Write-Notice 'Codex 프로젝트 로컬 설정에 Unity MCP를 등록합니다.'
        Invoke-Native -FilePath $script:UnityExe -Arguments @('mcp', 'configure', 'codex', '--local', '--project-path', $Path) | Out-Null
        Write-Notice 'Codex 프로젝트에 Unity CLI Skill을 설치합니다.'
        Invoke-Native -FilePath $script:UnityExe -Arguments @('skill', 'install', 'codex', '--local') | Out-Null
    }
    finally { Close-UnityStage6Window; Pop-Location }
    Write-Ok 'Pipeline + MCP + Unity CLI Skill 연동 완료'
    return $true
}

function Test-Connection {
    param([string]$Path)
    Write-Section '7/7  연결 상태 점검'
    $result = Invoke-Native -FilePath $script:UnityExe -Arguments @('status', '--project-path', $Path, '--format', 'json', '--non-interactive') -AllowFailure -Capture
    if (Test-UnityReadyJson -Text $result.Output -Path $Path -ExitCode $result.ExitCode) {
        Write-Ok '선택한 프로젝트의 Unity Editor 연결을 확인했습니다.'
    }
    else {
        Show-UnityStatusAdvice -Text $result.Output
        Write-Notice '설정은 완료됐지만 자동 연결 확인은 완료되지 않았습니다.'
        Write-Notice 'Unity 창으로 전환해 패키지 설치/컴파일 오류/Safe Mode를 확인한 뒤 다시 시도하세요.'
    }
}

function Invoke-BundleInstall {
    Write-Section 'Unity + Codex 설치 / 연동'
    Write-Host '지원 환경: Windows 10 21H1 이상 / Unity 6.0 이상'
    $project = Get-SelectedProject
    if (-not $project) { Write-Notice '취소했습니다.'; return }
    $logPath = Join-Path $env:TEMP ("Unity-Codex-Setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Start-BundleLog -Path $logPath
    Write-Ok "프로젝트: $project"
    Repair-UnityPackageJsonBom -Path $project
    $npmExe = Ensure-NodeAndNpm
    Ensure-Codex -NpmExe $npmExe
    Ensure-UnityCli
    Ensure-UnityLogin
    Ensure-CodexUnityPlugin
    if (-not (Ensure-PipelineAndLink -Path $project)) { return }
    Test-Connection -Path $project
    Write-Section '설치 / 연동 절차 완료'
    Write-Host 'Unity Editor를 켜고 프로젝트 폴더에서 codex를 실행하세요.' -ForegroundColor Green
    Write-Host '첫 테스트: 현재 연결된 Unity Editor 상태와 Scene Hierarchy를 확인해줘.'
    Write-Host "설치 로그: $logPath" -ForegroundColor Yellow
    $answer = Read-Host '지금 이 프로젝트에서 Codex를 실행할까요? (Y/N)'
    if ($answer -match '^[Yy예]') {
        Stop-BundleLog
        Push-Location -LiteralPath $project
        try { & $script:CodexExe }
        finally { Pop-Location }
    }
}

function Invoke-BundleRepair {
    Write-Section 'Unity 패키지 JSON의 UTF-8 BOM 복구'
    $project = Get-SelectedProject
    if (-not $project) { Write-Notice '취소했습니다.'; return }
    $logPath = Join-Path $env:TEMP ("Unity-JSON-Repair-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Start-BundleLog -Path $logPath
    Write-Ok "프로젝트: $project"
    Repair-UnityPackageJsonBom -Path $project
    Write-Host '검사가 끝났습니다. Unity 오류 창이 있다면 Retry를 누르세요.' -ForegroundColor Cyan
    Write-Host "복구 로그: $logPath" -ForegroundColor Yellow
}

function Invoke-BundleUninstall {
    Write-Section 'Unity + Codex 전체 제거'
    Write-Host '제거 대상:' -ForegroundColor Yellow
    Write-Host '- 선택 프로젝트의 Pipeline 패키지 참조, Unity MCP, Unity Skill'
    Write-Host '- 사용자 전역 설정의 Unity MCP, Unity 공식 Codex 플러그인'
    Write-Host '- Codex CLI, Unity CLI, Node.js LTS'
    Write-Host 'Unity Editor, Unity Hub, Assets와 게임 파일은 유지합니다.' -ForegroundColor Green
    $project = Get-SelectedProject
    if (-not $project) { Write-Notice '취소했습니다.'; return }
    $unityProcesses = @(Get-Process -Name 'Unity' -ErrorAction SilentlyContinue)
    if ($unityProcesses.Count -gt 0) {
        throw '모든 Unity Editor 창을 닫은 뒤 다시 실행하세요.'
    }
    Write-Host "대상 프로젝트: $project" -ForegroundColor Cyan
    Write-Host 'Node.js를 사용하는 다른 프로그램도 영향을 받을 수 있습니다.' -ForegroundColor Red
    $confirmation = Read-Host '전체 제거를 시작하려면 REMOVE ALL을 정확히 입력하세요'
    if ($confirmation -cne 'REMOVE ALL') {
        Write-Notice '취소했습니다. 아무것도 제거하지 않았습니다.'
        return
    }
    $script:BackupRoot = Join-Path $env:TEMP ("Unity-Codex-Uninstall-Backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    Start-BundleLog -Path (Join-Path $script:BackupRoot 'uninstall.log')
    Remove-ProjectIntegration -Path $project
    Remove-CodexPlugin
    Remove-CodexAndUnityCli
    Remove-NodeJs
    Write-Section '전체 제거 절차 완료'
    Write-Host '자동 제거를 건너뛴 항목은 위 안내와 로그를 확인하세요.' -ForegroundColor Yellow
    Write-Host "백업 및 로그: $script:BackupRoot" -ForegroundColor Yellow
    Write-Host '재설치하려면 PC를 재시작하고 이 파일에서 1번을 선택하세요.' -ForegroundColor Cyan
}

function Show-BundleHelp {
    Write-Section '사용 안내'
    Write-Host @"
이 BAT 파일 하나만 있으면 됩니다. 더블클릭하고 메뉴 번호를 입력하세요.

프로젝트 자동 탐색:
   설치/복구/제거를 선택하면 Unity Hub 기록과 문서/바탕 화면/다운로드,
   일반 프로젝트 폴더 및 로컬 드라이브에서 프로젝트를 찾습니다.
   목록의 프로젝트 번호를 선택하세요. 하나만 발견돼도 직접 선택합니다.
   기본 탐색: 깊이 5단계, 최대 8,000개 폴더, 약 12초.
   A: 추가 드라이브 탐색(깊이 10단계, 최대 40,000개 폴더, 약 30초).
   M: 폴더 직접 선택. 0: 프로젝트 선택 취소.
   Library/캐시/시스템 폴더, 연결 폴더와 네트워크 경로는 탐색에서 제외합니다.
   모든 프로젝트 발견을 보장하지 않으므로 누락되면 M으로 직접 선택하세요.

1. 설치 / 연동
   Unity 프로젝트 최상위 폴더(Assets, Packages, ProjectSettings)를 선택합니다.
   Node.js/npm, Codex CLI, Unity CLI, Unity 플러그인을 설치 또는 확인하고,
   프로젝트에 Pipeline, 로컬 MCP 설정, Unity CLI Skill을 연결합니다.
   브라우저가 열리면 Unity 계정으로 로그인하세요.
   Pipeline 패키지를 먼저 설치한 뒤 Unity Editor를 엽니다.
   선택한 프로젝트의 실행과 ready 상태를 자동 확인합니다.
   준비가 되면 자동 진행하며, 대기 중 M으로 수동 확인할 수도 있습니다.
   6단계에 별도 버튼 창이 표시됩니다. Unity가 열렸는데 진행이 멈췄다면
   "Unity 열렸음 · 계속 진행"을 클릭하세요. Pipeline/열기 명령이 끝나지 않아도
   실제 준비가 끝났다고 수동 확인하면 MCP 설정으로 진행됩니다.
   M은 Unity가 열리고 패키지 설치/컴파일이 끝났음을 직접 확인한 경우 선택하세요.
   자동 확인 실패 시 A: 다시 확인, M: 수동으로 계속, 0: 취소.
   수동 확인은 설정 절차를 계속 진행하며 실제 연결 성공을 보장하지 않습니다.
   마지막에 Codex를 실행할지 선택할 수 있습니다.

2. JSON 복구
   선택한 프로젝트의 manifest.json과 packages-lock.json에서 UTF-8 BOM을
   검사하고 제거합니다. 수정 전 원본은 TEMP 폴더에 백업합니다.
   Char: 65279 / Non-whitespace before 오류가 날 때 사용하세요.
   그 밖의 JSON 문법 오류는 자동으로 고치지 않습니다.

3. 전체 제거
   모든 Unity Editor 창을 먼저 닫으세요.
   프로젝트를 선택하고 REMOVE ALL을 정확히 입력해야 제거합니다.
   선택 프로젝트의 Pipeline, Unity MCP, Unity Skill 및 사용자 전역 Unity
   MCP 설정과 Unity 플러그인, Codex CLI, Unity CLI, Node.js LTS가 대상입니다.
   Node.js를 사용하는 다른 프로그램에도 영향을 줄 수 있습니다.
   Unity Editor, Unity Hub, 프로젝트 Assets/Scenes/Scripts는 유지합니다.
   변경 전 설정과 제거한 Skill은 TEMP 폴더에 백업합니다.

지원 환경: Windows 10 21H1 이상, Unity 6.0 이상, 인터넷 연결
필요 계정: Unity 계정, Codex 사용 가능한 ChatGPT/OpenAI 계정

Unity가 Safe Mode이면 C# 컴파일 오류를 먼저 해결하세요.
플러그인 서버 오류가 발생하면 플러그인은 건너뛰고 나머지 연동을 진행합니다.
설치를 다시 실행해도 되며, 이미 설치된 항목은 확인 후 건너뜁니다.
로그와 백업 위치는 작업 결과에 표시됩니다.

첫 테스트 문장:
현재 연결된 Unity Editor 상태와 Scene Hierarchy를 확인해줘.
현재 Scene에 Cube를 하나 만들고 이름을 Player로 바꿔줘.

공식 문서:
https://developers.openai.com/docs/codex/cli
https://docs.unity.com/en-us/unity-cli/use-unity-cli
https://docs.unity.com/en-us/unity-production-pipeline/local-tools-cli/unity-pipeline-package
https://github.com/Unity-Technologies/unity-agent-plugin
"@
}

function Start-BundleMenu {
    $Host.UI.RawUI.WindowTitle = 'Unity + Codex 통합 도구'
    while ($true) {
        Write-Section 'Unity + Codex 통합 도구'
        Write-Host '  1. 설치 / 연동'
        Write-Host '  2. Unity JSON 복구'
        Write-Host '  3. 전체 제거' -ForegroundColor Yellow
        Write-Host '  4. 사용 안내'
        Write-Host '  0. 종료'
        $choice = Read-Host '번호를 입력하세요'
        if ($choice -eq '0') { return }
        $script:LastLog = $null
        try {
            switch ($choice) {
                '1' { Invoke-BundleInstall }
                '2' { Invoke-BundleRepair }
                '3' { Invoke-BundleUninstall }
                '4' { Show-BundleHelp; [void](Read-Host '메뉴로 돌아가려면 Enter를 누르세요') }
                default { Write-Notice '0~4 중에서 선택하세요.' }
            }
        }
        catch {
            Write-Host "[오류] $($_.Exception.Message)" -ForegroundColor Red
            if ($script:LastLog) { Write-Host "로그 위치: $script:LastLog" -ForegroundColor Yellow }
            Write-Notice '오류를 확인하고 메뉴에서 다시 실행할 수 있습니다.'
        }
        finally { Stop-BundleLog }
    }
}

try { Start-BundleMenu }
finally { Stop-BundleLog }