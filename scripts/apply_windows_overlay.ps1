param([Parameter(Mandatory=$true)][string]$PlanPath)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$plan = [IO.File]::ReadAllText($PlanPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$log = Join-Path $plan.Transaction 'install.log'
$resultPath = Join-Path $plan.Transaction 'result.json'
if ($plan.Phase -notin @('seed','finish','recover') -or $plan.Build -notmatch '^[0-9a-f]{32}$' -or
    $plan.PackageFullName -ne 'Claude_4.29.0.0_x64__pzs8sxrjxfjjc' -or $plan.PackageVersion -ne '4.29.0.0') {
    throw 'Unsupported or malformed overlay plan.'
}
$expectedRoot = Join-Path $env:ProgramFiles ('WindowsApps\' + $plan.PackageFullName)
$expectedConfig = Join-Path $env:LOCALAPPDATA 'Claude-3p\config.json'
if ($plan.PackageRoot -ne $expectedRoot -or $plan.AppRoot -ne (Join-Path $expectedRoot 'app') -or
    $plan.ConfigPath -ne $expectedConfig -or $plan.Transaction -ne (Split-Path -Parent ([IO.Path]::GetFullPath($PlanPath))) -or
    $plan.BackupRootName -ne ('.zh-cn-overlay-' + $plan.Build + '-' + $plan.Phase)) { throw 'Plan paths do not match the current user/package.' }
$expectedFiles = @('resources\app.asar','resources\ion-dist.asar','Claude.exe')
if ($plan.Entries.Count -ne 3 -or @(Compare-Object $expectedFiles @($plan.Entries.Relative)).Count) { throw 'Unexpected file set.' }
foreach ($entry in $plan.Entries) {
    $relative = if ($entry.Relative -eq 'Claude.exe') {'_app\Claude.exe'} else {$entry.Relative.Substring(10)}
    if ($entry.BackupRelative -ne $relative -or $entry.BeforeSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $entry.AfterSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Malformed entry.' }
}
if ($plan.Phase -eq 'finish') {
    $manifestPath = Join-Path (Split-Path -Parent $plan.Transaction) 'overlay\overlay-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $readinessFile = Join-Path $env:LOCALAPPDATA 'Claude-3p\logs\claude.ai-web.log'
    if ($manifest.build -ne $plan.Build -or $plan.ReadyMarker -ne $manifest.readyMarker -or
        -not (Select-String -LiteralPath $readinessFile -SimpleMatch $plan.ReadyMarker -Quiet)) {
        throw 'This overlay has not reported READY. Use recover instead if seeding failed.'
    }
}
Start-Transcript -LiteralPath $log -Force | Out-Null
$mutex = [Threading.Mutex]::new($false, 'Global\ClaudeDesktopZhCn-Installer')
$locked = $false
$aclSnapshots = @()
$changed = @()
$configChanged = $false
$serviceWasRunning = $false
$successful = $false
$failure = $null
$backupSet = $null

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class ClaudePatchPrivilege {
    public static void ReplaceFile(string source, string destination) {
        System.IO.File.Replace(source, destination, null);
    }
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern uint SetNamedSecurityInfo(string name, int type, uint info, byte[] owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    public static void Enable(string name) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception();
        try {
            Luid luid;
            if (!LookupPrivilegeValue(null, name, out luid)) throw new Win32Exception();
            var state = new TokenPrivileges { Count=1, Luid=luid, Attributes=2 };
            if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
            int error=Marshal.GetLastWin32Error();
            if (error!=0) throw new Win32Exception(error);
        } finally { CloseHandle(token); }
    }
    public static void Own(string path, SecurityIdentifier sid) {
        var bytes=new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes,0);
        uint error=SetNamedSecurityInfo(path,1,1,bytes,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
        if (error!=0) throw new Win32Exception((int)error);
    }
}
'@

function Assert-CurrentPackage {
    $package = Get-AppxPackage -Name Claude -ErrorAction Stop
    if ($package.PackageFullName -ne $plan.PackageFullName -or $package.Status -ne 'Ok' -or
        $package.InstallLocation -ne $plan.PackageRoot) { throw 'Claude package identity/status changed. Aborting.' }
    foreach ($directory in Get-ChildItem -LiteralPath (Split-Path -Parent $plan.PackageRoot) -Directory -Filter 'Claude_*') {
        if ($directory.Name -match '^Claude_(\d+\.\d+\.\d+\.\d+)_x64__pzs8sxrjxfjjc$' -and
            [version]$Matches[1] -gt [version]$plan.PackageVersion) {
            throw "A newer staged Claude package exists: $($directory.Name)"
        }
    }
}

function Grant-ExactPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $allowed = @($plan.AppRoot, (Join-Path $plan.AppRoot 'resources')) + @($plan.Entries | ForEach-Object { Join-Path $plan.AppRoot $_.Relative })
    if ($full -notin $allowed) { throw "Refusing permissions outside the five approved paths: $full" }
    $acl = Get-Acl -LiteralPath $full
    $script:aclSnapshots += [pscustomobject]@{ Path=$full; Sddl=$acl.GetSecurityDescriptorSddlForm('Owner,Group,Access') }
    [ClaudePatchPrivilege]::Own($full, $script:identity.User)
    $acl = Get-Acl -LiteralPath $full
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($script:identity.User, 'FullControl', 'None', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $full -AclObject $acl
}

function New-PrivateBackupDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw "Backup path already exists: $Path" }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($script:identity.User)
    foreach ($sid in @($script:identity.User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
}

function Replace-CheckedFile([string]$Source, [string]$Destination, [string]$ExpectedHash) {
    if ((Get-FileHash -LiteralPath $Source).Hash -ne $ExpectedHash) { throw "Source hash mismatch: $Source" }
    $temporary = $Destination + '.zh-tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        if ((Get-FileHash -LiteralPath $temporary).Hash -ne $ExpectedHash) { throw 'Temporary copy hash mismatch.' }
        # New files inherit WindowsApps' read-only DACL. ReplaceFile also needs
        # write/delete access to its source, even though this process created it.
        $tempAcl = Get-Acl -LiteralPath $temporary
        $tempAcl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($script:identity.User, 'FullControl', 'Allow'))
        Set-Acl -LiteralPath $temporary -AclObject $tempAcl
        [ClaudePatchPrivilege]::ReplaceFile($temporary, $Destination)
        if ((Get-FileHash -LiteralPath $Destination).Hash -ne $ExpectedHash) { throw "Installed hash mismatch: $Destination" }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        $identity.User.Value -ne $plan.UserSid) { throw 'Run elevated as the original user, not a different account.' }
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another language-pack installer is running.' }
    Assert-CurrentPackage

    foreach ($entry in $plan.Entries) {
        $destination = Join-Path $plan.AppRoot $entry.Relative
        $currentHash = (Get-FileHash -LiteralPath $destination).Hash
        if ($currentHash -ne $entry.BeforeSha256 -and -not ($plan.Phase -in @('finish','recover') -and $currentHash -eq $entry.AfterSha256)) { throw "Unexpected installed file: $destination" }
        if ((Get-FileHash -LiteralPath $entry.Original).Hash -ne $entry.BeforeSha256 -or
            (Get-FileHash -LiteralPath $entry.Patched).Hash -ne $entry.AfterSha256) { throw 'Verified inputs changed.' }
    }
    foreach ($process in Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'") {
        if ($process.ExecutablePath -ieq (Join-Path $plan.AppRoot 'Claude.exe')) {
            $p = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
            if ($p) { [void]$p.CloseMainWindow() }
        }
    }
    Start-Sleep -Seconds 2
    foreach ($process in Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'") {
        if ($process.ExecutablePath -ieq (Join-Path $plan.AppRoot 'Claude.exe')) { Stop-Process -Id $process.ProcessId -Force }
    }
    $service = Get-CimInstance Win32_Service -Filter "Name = 'CoworkVMService'"
    if ($service -and $service.PathName.Trim('"') -ine (Join-Path $plan.AppRoot 'resources\cowork-svc.exe')) {
        throw 'Cowork service points to another package.'
    }
    $serviceWasRunning = $service -and $service.State -eq 'Running'
    if ($serviceWasRunning) {
        Stop-Service -Name CoworkVMService -ErrorAction Stop
        (Get-Service CoworkVMService).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(45))
    }
    Assert-CurrentPackage
    foreach ($privilege in @('SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege')) { [ClaudePatchPrivilege]::Enable($privilege) }
    foreach ($path in @($plan.AppRoot, (Join-Path $plan.AppRoot 'resources'))) { Grant-ExactPath $path }
    foreach ($entry in $plan.Entries) { Grant-ExactPath (Join-Path $plan.AppRoot $entry.Relative) }
    [IO.File]::WriteAllText((Join-Path $plan.Transaction 'original-acls.json'), ($aclSnapshots | ConvertTo-Json -Depth 5), $utf8)

    $backupRoot = Join-Path $plan.AppRoot ('resources\' + $plan.BackupRootName)
    if (Test-Path -LiteralPath $backupRoot) {
        $previous = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($previous.Success -or $previous.Package -ne $plan.PackageFullName -or -not $previous.BackupSet) {
            throw 'Existing backup is not from this failed installation.'
        }
        $backupSet = [IO.Path]::GetFullPath($previous.BackupSet)
        if (-not $backupSet.StartsWith($backupRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup path escaped expected root.' }
    } else {
        New-PrivateBackupDirectory $backupRoot
        $backupSet = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-4.29-verified')
        New-Item -ItemType Directory -Path (Join-Path $backupSet '_app') -Force | Out-Null
    }
    foreach ($entry in $plan.Entries) {
        $destination = Join-Path $plan.AppRoot $entry.Relative
        $backup = Join-Path $backupSet $entry.BackupRelative
        if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::Copy($entry.Original, $backup, $false) }
        if ((Get-FileHash -LiteralPath $backup).Hash -ne $entry.BeforeSha256) { throw 'Backup verification failed.' }
    }
    if (-not (Test-Path -LiteralPath $plan.ConfigPath)) { throw 'Expected Claude-3p config is missing.' }
    $configBackup = Join-Path $plan.Transaction 'config.before.json'
    if (Test-Path -LiteralPath $configBackup) {
        if ((Get-FileHash -LiteralPath $configBackup).Hash -ne (Get-FileHash -LiteralPath $plan.ConfigPath).Hash) {
            throw 'User configuration changed since the previous attempt.'
        }
    } else { [IO.File]::Copy($plan.ConfigPath, $configBackup, $false) }
    $config = [IO.File]::ReadAllText($plan.ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($config -isnot [pscustomobject]) { throw 'User config is not a JSON object.' }
    $config | Add-Member -NotePropertyName locale -NotePropertyValue $plan.Locale -Force
    [IO.File]::WriteAllText((Join-Path $plan.Transaction 'config.patched.json'), ($config | ConvertTo-Json -Depth 100), $utf8)
    foreach ($entry in $plan.Entries) {
        Assert-CurrentPackage
        $destination = Join-Path $plan.AppRoot $entry.Relative
        $sourceFile = $entry.Patched
        $hash = $entry.AfterSha256
        if ((Get-FileHash -LiteralPath $destination).Hash -eq $hash) { continue }
        $changed += $entry
        Replace-CheckedFile $sourceFile $destination $hash
        Write-Host "Verified replacement: $($entry.Relative)"
    }
    $configSource = Join-Path $plan.Transaction 'config.patched.json'
    $configChanged = $true
    Replace-CheckedFile $configSource $plan.ConfigPath (Get-FileHash -LiteralPath $configSource).Hash
    Assert-CurrentPackage
    if ($plan.Phase -in @('finish','recover') -and (Get-AuthenticodeSignature -LiteralPath (Join-Path $plan.AppRoot 'Claude.exe')).Status -ne 'Valid') { throw 'Official signature was not restored.' }
    $successful = $true
} catch {
    $failure = $_.Exception.ToString()
    Write-Host "FAILED: $failure"
    if ($plan.Phase -eq 'seed') {
        try {
            Assert-CurrentPackage
            foreach ($entry in $changed) {
                if ((Get-FileHash -LiteralPath (Join-Path $plan.AppRoot $entry.Relative)).Hash -eq $entry.BeforeSha256) { continue }
                Replace-CheckedFile $entry.Original (Join-Path $plan.AppRoot $entry.Relative) $entry.BeforeSha256
                Write-Host "Rolled back: $($entry.Relative)"
            }
            if ($configChanged) {
                $originalConfig = Join-Path $plan.Transaction 'config.before.json'
                Replace-CheckedFile $originalConfig $plan.ConfigPath (Get-FileHash -LiteralPath $originalConfig).Hash
            }
        } catch { $failure += "`nROLLBACK ERROR: " + $_.Exception.ToString() }
    }
} finally {
    [Array]::Reverse($aclSnapshots)
    foreach ($snapshot in $aclSnapshots) {
        try {
            $acl = Get-Acl -LiteralPath $snapshot.Path
            $acl.SetSecurityDescriptorSddlForm($snapshot.Sddl, 'Owner,Group,Access')
            Set-Acl -LiteralPath $snapshot.Path -AclObject $acl
        } catch { $successful = $false; $failure += "`nACL RESTORE ERROR: $($snapshot.Path): " + $_.Exception.Message }
    }
    if ($serviceWasRunning) {
        try { Start-Service -Name CoworkVMService -ErrorAction Stop }
        catch { $successful = $false; $failure += "`nSERVICE START ERROR: " + $_.Exception.Message }
    }
    $result = [ordered]@{ Success=$successful; Phase=$plan.Phase; Package=$plan.PackageFullName; BackupSet=$backupSet; Error=$failure }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5), $utf8)
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Stop-Transcript | Out-Null
}
if (-not $successful) { exit 1 }
