# Exercise the per-user MSI in a disposable GitHub-hosted Windows account.
param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference = 'Stop'
trap {
    Write-Output $_.ScriptStackTrace
    throw $_
}
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run this registration test on a disposable GitHub-hosted Windows runner.'
}
$work = Join-Path $env:RUNNER_TEMP ('usage-install-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$oldMsi = Join-Path $work 'previous-test-version.msi'
Copy-Item -LiteralPath $Installer -Destination $oldMsi
$testCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$engine = New-Object -ComObject WindowsInstaller.Installer
function Get-MsiValue($database, [string]$sql) {
    $query = $database.OpenView($sql)
    [void]$query.Execute()
    $row = $query.Fetch()
    $value = $row.StringData(1)
    [void]$query.Close()
    return [string]$value
}
function Set-MsiValue($database, [string]$key, [string]$value) {
    $query = $database.OpenView("UPDATE Property SET Value='$value' WHERE Property='$key'")
    $query.Execute()
    $query.Close()
}
function Invoke-Installer([string]$verb, [string]$package, [string]$step) {
    $log = Join-Path $work ($step + '.log')
    $proc = Start-Process msiexec.exe -ArgumentList "$verb ""$package"" /qn /norestart /L*v ""$log""" -WindowStyle Hidden -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        Select-String -LiteralPath $log -Pattern 'Return value 3|Error [0-9]{4}|MainEngineThread is returning' -Context 3,0
        throw "$step returned $($proc.ExitCode)"
    }
    Write-Output "$step passed."
}

# Only the disposable fixture has a synthetic identity and a lower version.
$db = $engine.OpenDatabase($oldMsi, 1)
$productCode = Get-MsiValue $db "SELECT Value FROM Property WHERE Property='ProductCode'"
$version = Get-MsiValue $db "SELECT Value FROM Property WHERE Property='ProductVersion'"
Set-MsiValue $db 'ProductCode' $testCode
Set-MsiValue $db 'ProductVersion' '0.0.1'
$summary = $db.SummaryInformation(1)
$summary.Property(9) = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$summary.Persist()
$db.Commit()
$null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary)
$null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
[GC]::Collect()
[GC]::WaitForPendingFinalizers()

$appdir = Join-Path $env:LOCALAPPDATA 'Programs\Usage Monitor'
$data = Join-Path $env:LOCALAPPDATA 'UsageMonitor'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Usage Monitor.lnk'
if ((Test-Path -LiteralPath $appdir) -or (Test-Path -LiteralPath $data)) {
    throw 'The release test requires a clean account.'
}
Invoke-Installer '/i' $Installer 'Install on a clean PC'
if (!(Test-Path -LiteralPath $shortcut) -or !(Test-Path -LiteralPath (Join-Path $appdir 'desktop.py'))) {
    throw 'Fresh installation did not create the launcher and Start shortcut.'
}
Invoke-Installer '/x' $productCode 'Remove first installation'
Invoke-Installer '/i' $oldMsi 'Install previous-version fixture'
if ($engine.ProductState($testCode) -ne 5) { throw 'Previous version did not register.' }
$null = New-Item -ItemType Directory -Path $data
$settings = '{"mode":"personal","claude":"manual","codex":"manual","folder":""}'
[IO.File]::WriteAllText((Join-Path $data 'settings.json'),$settings)
$manualDir = Join-Path $data 'manual'
$null = New-Item -ItemType Directory -Path $manualDir
$observed = [datetime]::UtcNow
$sample = @{observed_at=$observed.ToString('o');windows=@(@{label='Weekly';used=23;resets_at=$observed.AddDays(3).ToString('o')})} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $manualDir 'codex.json'),$sample)
Invoke-Installer '/i' $Installer 'Upgrade to release'
if ($engine.ProductState($testCode) -eq 5 -or $engine.ProductState($productCode) -ne 5) {
    throw 'Upgrade registration mismatch.'
}
Write-Output 'Verified the upgrade registered exactly one current product.'
if (!(Test-Path -LiteralPath $shortcut)) {
    foreach ($log in (Get-ChildItem -LiteralPath $work -Filter '*.log')) {
        Select-String -LiteralPath $log.FullName -Pattern 'Dir \(target\): Key: ProgramMenuFolder|Executing op: Shortcut|Warning 19[0-9]{2}|Component: StartShortcut;|Note: 1: 19[0-9]{2}|Skipping action: CreateShortcuts|Disallowing installation of component|Skipping component: StartShortcut|Another client' |
            ForEach-Object { $_.Line }
    }
    foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))) {
        Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*Usage*' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    }
    throw 'Start menu shortcut missing.'
}
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$expectedTarget = Join-Path $appdir 'runtime\pythonw.exe'
if ($link.TargetPath -ne $expectedTarget -or $link.Arguments -ne ('-B "' + (Join-Path $appdir 'desktop.py') + '"')) {
    throw 'The Start menu shortcut does not target the installed launcher.'
}
Write-Output 'Verified the registered Start menu command.'
$app = Start-Process -FilePath $link.TargetPath -ArgumentList ($link.Arguments + ' --no-browser') -WindowStyle Hidden -PassThru
try {
    $feed = $null
    for ($i=0; $i -lt 80; $i++) {
        try {
            $instance = Get-Content -Raw -LiteralPath (Join-Path $data 'instance.json') | ConvertFrom-Json
            $base = 'http://127.0.0.1:' + $instance.port
            $feed = Invoke-RestMethod "$base/usage.json" -TimeoutSec 2
            break
        } catch { Start-Sleep -Milliseconds 200 }
    }
    if ($feed.mode -ne 'personal' -or $feed.providers.codex.windows[0].used -ne 23) {
        throw 'The installed app failed to read the settings and reading saved before upgrade.'
    }
    $state = Invoke-RestMethod "$base/api/state"
    if ($state.version -ne $version) { throw 'The app version differs from the installer.' }
    $page = (Invoke-WebRequest "$base/settings" -UseBasicParsing).Content
    $token = [regex]::Match($page,'name="action-token" content="([^"]+)"').Groups[1].Value
    $null = Invoke-RestMethod "$base/api/quit" -Method Post -Headers @{'X-Usage-Monitor'=$token} -ContentType 'application/json' -Body '{}'
    if (!$app.WaitForExit(10000)) { throw 'App shutdown timed out.' }
    Write-Output 'Start menu target, packaged application and pre-upgrade readings passed.'
} finally {
    if (!$app.HasExited) { $app.Kill(); $app.WaitForExit() }
}
Invoke-Installer '/x' $productCode 'Uninstall release'
if ((Test-Path -LiteralPath $shortcut) -or (Test-Path -LiteralPath $expectedTarget) -or $engine.ProductState($productCode) -eq 5) {
    throw 'Product files or registration remain after uninstall.'
}
if ([IO.File]::ReadAllText((Join-Path $data 'settings.json')) -ne $settings -or
    [IO.File]::ReadAllText((Join-Path $manualDir 'codex.json')) -ne $sample) {
    throw 'User settings or readings changed during setup or removal.'
}
Write-Output 'Windows installation, upgrade, application launch, data retention and uninstall passed.'
