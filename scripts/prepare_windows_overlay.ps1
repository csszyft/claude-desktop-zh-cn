param([Parameter(Mandatory=$true)][string]$Workspace)
$ErrorActionPreference = 'Stop'
$repoScripts = $PSScriptRoot
$workspaceFull = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $workspaceFull) { throw 'Use a new, empty workspace path outside the repository.' }
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $repoScripts)).TrimEnd('\')
if ($workspaceFull -eq $repo -or $workspaceFull.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Workspace contains private config/backups later. Keep it outside the repository.'
}
$package = Get-AppxPackage -Name Claude
if ($package.Version -ne [version]'4.29.0.0' -or $package.Status -ne 'Ok' -or
    $package.PackageFullName -ne 'Claude_4.29.0.0_x64__pzs8sxrjxfjjc') {
    throw 'This experimental workflow only supports Claude 4.29.0.0 x64 (Claude_pzs8sxrjxfjjc).'
}
$appRoot = Join-Path $package.InstallLocation 'app'
if ((Get-AuthenticodeSignature -LiteralPath (Join-Path $appRoot 'Claude.exe')).Status -ne 'Valid') {
    throw 'Restore the official Claude package first. Do not use a patched EXE as the original backup.'
}
& python -c 'import sys; assert sys.version_info >= (3,10)'
if ($LASTEXITCODE -ne 0) { throw 'Python 3.10+ is required.' }

$installerText = [IO.File]::ReadAllText((Join-Path $repoScripts 'install_windows.ps1'))
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($installerText,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Name})
. (Join-Path $repoScripts 'load_windows_functions.ps1') -FunctionNames $names
$Utf8NoBom=[Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize=4MB
$BaseLanguageList='["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"'
$LanguageListPattern=[regex]::Escape($BaseLanguageList)+'(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]'
$script:CurrentBackupSetPath=$null
$script:SkipFrontendFileBackups=$false
$originalApp=Join-Path $workspaceFull 'original\app'
$patchedApp=Join-Path $workspaceFull 'patched\app'
$relativeFiles=@('resources\app.asar','resources\ion-dist.asar','Claude.exe')
$hashes=@{}
foreach ($target in @($originalApp,$patchedApp)) {
    New-Item -ItemType Directory -Path (Join-Path $target 'resources') -Force | Out-Null
    foreach ($relative in $relativeFiles) {
        Copy-Item -LiteralPath (Join-Path $appRoot $relative) -Destination (Join-Path $target $relative)
    }
}
foreach ($relative in $relativeFiles) {
    $hashes[$relative]=(Get-FileHash -LiteralPath (Join-Path $originalApp $relative)).Hash
}
$resources=Join-Path $patchedApp 'resources'
$target=Initialize-FrontendPatchTarget $resources
try {
    Install-LanguageFiles $resources (Get-LanguageResources 'zh-CN') 'zh-CN'
    Register-Language $resources 'zh-CN'
    Patch-HardcodedFrontendStrings $resources 'zh-CN'
    Patch-SlashCommandMenu $resources 'zh-CN'
    Patch-LanguageDisplayNames $resources
    Complete-FrontendPatchTarget $target
} finally { Close-FrontendPatchTarget $target }
$overlay=Join-Path $workspaceFull 'overlay'
& python (Join-Path $repoScripts 'build_windows_overlay.py') --original-app $originalApp --patched-app $patchedApp --output $overlay
if ($LASTEXITCODE -ne 0) { throw 'Overlay build failed. No installed files were changed.' }
$manifest=Get-Content -LiteralPath (Join-Path $overlay 'overlay-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($phase in @('seed','finish','recover')) {
    $transaction=Join-Path $workspaceFull $phase
    New-Item -ItemType Directory -Path $transaction | Out-Null
    $plan=[ordered]@{
        PackageFullName=$package.PackageFullName; PackageVersion=[string]$package.Version
        PackageRoot=$package.InstallLocation; AppRoot=$appRoot
        UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ConfigPath=(Join-Path $env:LOCALAPPDATA 'Claude-3p\config.json')
        Transaction=$transaction; Phase=$phase; Build=$manifest.build
        ReadyMarker=$manifest.readyMarker
        ReadinessFile=(Join-Path $env:LOCALAPPDATA 'Claude-3p\logs\claude.ai-web.log')
        BackupRootName=('.zh-cn-overlay-' + $manifest.build + '-' + $phase)
        Locale=$(if ($phase -eq 'seed') {'zh-CN'} elseif ($phase -eq 'recover') {'en-US'} else {'zh-Hans'})
        Entries=@()
    }
    foreach ($relative in $relativeFiles) {
        $original=Join-Path $originalApp $relative
        # Seed the translated copy; finish restores every original package file.
        $seed=if ($relative -eq 'Claude.exe') {Join-Path $overlay 'Claude-bootstrap.exe'} elseif ($relative.EndsWith('ion-dist.asar')) {Join-Path $overlay 'ion-dist-bootstrap.asar'} else {Join-Path $patchedApp $relative}
        $before=if ($phase -eq 'seed') {$original} else {$seed}
        $after=if ($phase -eq 'seed') {$seed} else {$original}
        $plan.Entries+=@{Relative=$relative;Original=$before;Patched=$after;BeforeSha256=(Get-FileHash -LiteralPath $before).Hash;AfterSha256=(Get-FileHash -LiteralPath $after).Hash;BackupRelative=$(if ($relative -eq 'Claude.exe') {'_app\Claude.exe'} else {$relative.Substring(10)})}
    }
    [IO.File]::WriteAllText((Join-Path $transaction 'plan.json'), ($plan|ConvertTo-Json -Depth 10), $Utf8NoBom)
}
foreach ($relative in $relativeFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path $appRoot $relative)).Hash -ne $hashes[$relative]) { throw 'Claude changed during preparation; discard these plans.' }
}
if ((Get-AppxPackage -Name Claude).PackageFullName -ne $package.PackageFullName) { throw 'Claude version changed during preparation.' }
Write-Host "Prepared plans in $workspaceFull. No installed files or user settings were modified."
Write-Host 'Read docs/windows-overlay.md before running the seed/finish phases.'
