$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Require-File', 'Align-4', 'Get-UInt32LE', 'Get-Int32LE', 'Get-Sha256Hex',
    'Read-AsarHeader', 'Read-AsarHeaderFromFile', 'Get-AsarFileIntegrity', 'New-AsarArchive',
    'Get-BackupRoot', 'New-BackupSet', 'Get-RelativeResourcePath', 'Backup-ModifiedFile',
    'Get-ClaudeAppPathFromResources', 'Backup-AppFile', 'Restore-LatestBackup',
    'Format-ByteSize', 'Get-AsarHeaderHash', 'Sync-ClaudeExeAsarIntegrity',
    'Merge-TranslationCatalog', 'Install-MergedCatalog', 'Get-AsarCatalogText',
    'Install-DesktopCatalog', 'Install-LanguageFiles', 'Get-LanguageResources',
    'Get-ClaudeConfigPaths', 'Set-ClaudeLocale', 'Save-JsonNoBom'
)

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (actual: $Actual, expected: $Expected)" }
}
function Write-Fixture([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}
function Read-Catalog([string]$Path) {
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\', '/')
$temp = [IO.Path]::GetFullPath((Join-Path $workspace ('.tmp-i18n-' + [guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path' }
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB
$oldLocal = $env:LOCALAPPDATA
$oldRoaming = $env:APPDATA

try {
    $translation = Join-Path $temp 'translations.json'
    $pairs = Join-Path $temp 'pairs.json'
    Write-Fixture $translation '{"menu":"\u6587\u4ef6","translated":"custom","oldKey":"old"}'
    Write-Fixture $pairs '[["For your toughest challenges","tough-translated"],["Most capable for ambitious work","capable-translated"],["Same text","must-not-override"]]'
    $english = '{"menu":"File","translated":"Same text","newKey":"New version {name}","tough":"For your toughest challenges","capable":"Most capable for ambitious work","partial":"Prefix For your toughest challenges","lower":"file"}'
    $merged = Merge-TranslationCatalog $english $translation $pairs | ConvertFrom-Json
    Assert-Equal $merged.menu ([string][char]0x6587 + [char]0x4ef6) 'UTF-8 translation'
    Assert-Equal $merged.translated 'custom' 'Key translation wins over string mapping'
    Assert-Equal $merged.newKey 'New version {name}' 'Unknown ICU text preserved'
    Assert-Equal $merged.tough 'tough-translated' 'Model description translated without bundle literals'
    Assert-Equal $merged.capable 'capable-translated' 'Second model description translated'
    Assert-Equal $merged.partial 'Prefix For your toughest challenges' 'No substring replacement'
    Assert-Equal $merged.lower 'file' 'Case-sensitive lookup'

    $resources = Join-Path $temp 'legacy\app\resources'
    $source = Join-Path $temp 'legacy-source'
    Write-Fixture (Join-Path $source 'index.js') 'console.log("untouched");'
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    New-AsarArchive $source (Join-Path $resources 'app.asar')
    $originalAsar = (Get-FileHash (Join-Path $resources 'app.asar')).Hash
    $script:CurrentBackupSetPath = $null
    Write-Fixture (Join-Path $resources 'en-US.json') $english
    Write-Fixture (Join-Path $resources 'ion-dist\i18n\en-US.json') $english
    Write-Fixture (Join-Path $resources 'ion-dist\i18n\dynamic\en-US.json') '{"dynamic":"unchanged"}'
    $statsig = Join-Path $temp 'statsig.json'
    Write-Fixture $statsig '{}'
    $pack = @{ Frontend = $translation; FrontendHardcoded = $pairs; Desktop = $translation; Statsig = $statsig }
    Install-LanguageFiles $resources $pack 'zh-CN'
    Assert-Equal $script:PatchedDesktopAsar $false 'Legacy mode must not touch app.asar or require Claude.exe'
    Assert-Equal (Get-FileHash (Join-Path $resources 'app.asar')).Hash $originalAsar 'Original app.asar unchanged'
    foreach ($path in @('en-US.json', 'zh-CN.json', 'ion-dist\i18n\en-US.json', 'ion-dist\i18n\zh-CN.json')) {
        $catalog = Read-Catalog (Join-Path $resources $path)
        Assert-Equal $catalog.menu $merged.menu "Legacy menu: $path"
        Assert-Equal $catalog.newKey 'New version {name}' "Current-version key retained: $path"
    }
    if ($null -eq (Read-Catalog (Join-Path $resources 'ion-dist\i18n\dynamic\zh-CN.json'))) { throw 'Dynamic catalog missing' }
    Assert-Equal (Read-Catalog (Join-Path $resources 'ion-dist\i18n\dynamic\en-US.json')).dynamic 'unchanged' 'Dynamic English unchanged'
    $backup = New-BackupSet $resources
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $backup 'en-US.json'))) $english 'Original desktop catalog backed up'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $backup 'ion-dist\i18n\en-US.json'))) $english 'Original frontend catalog backed up'
    Restore-LatestBackup $resources
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $resources 'en-US.json'))) $english 'Desktop catalog restored'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $resources 'ion-dist\i18n\en-US.json'))) $english 'Frontend catalog restored'

    $resources = Join-Path $temp 'packed\app\resources'
    $source = Join-Path $temp 'packed-source'
    Write-Fixture (Join-Path $source 'resources\i18n\en-US.json') $english
    Write-Fixture (Join-Path $source 'index.js') 'console.log("untouched");'
    Write-Fixture (Join-Path $source 'native.node') 'native payload'
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    $asar = Join-Path $resources 'app.asar'
    New-AsarArchive $source $asar
    # Add link/unpacked/executable metadata without requiring a native module on disk.
    $data = [IO.File]::ReadAllBytes($asar)
    $parsed = Read-AsarHeader $data $asar
    $parsed.Header.files.'native.node' | Add-Member -NotePropertyName unpacked -NotePropertyValue $true
    $parsed.Header.files.'index.js' | Add-Member -NotePropertyName executable -NotePropertyValue $true
    $parsed.Header.files | Add-Member -NotePropertyName alias -NotePropertyValue ([pscustomobject]@{link='index.js'})
    $headerBytes = [Text.Encoding]::UTF8.GetBytes(($parsed.Header | ConvertTo-Json -Depth 100 -Compress))
    $payloadSize = Align-4 (4 + $headerBytes.Length)
    $headerSize = 4 + $payloadSize
    $prefix = [byte[]]::new(8 + $headerSize)
    [Array]::Copy([BitConverter]::GetBytes([uint32]4), 0, $prefix, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerSize), 0, $prefix, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$payloadSize), 0, $prefix, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$headerBytes.Length), 0, $prefix, 12, 4)
    [Array]::Copy($headerBytes, 0, $prefix, 16, $headerBytes.Length)
    $stream = [IO.File]::Create($asar)
    try {
        $stream.Write($prefix, 0, $prefix.Length)
        $stream.Write($data, 8 + $parsed.HeaderSize, $data.Length - 8 - $parsed.HeaderSize)
    } finally { $stream.Dispose() }
    $originalAsar = (Get-FileHash $asar).Hash
    $originalHeader = (Read-AsarHeaderFromFile $asar).Header
    $exe = Join-Path (Split-Path -Parent $resources) 'Claude.exe'
    Write-Fixture $exe ('resources\\app.asar","alg":"SHA256","value":"' + (Get-AsarHeaderHash $asar) + '"}')
    $originalExe = (Get-FileHash $exe).Hash
    $script:CurrentBackupSetPath = $null
    foreach ($lang in @('zh-CN', 'zh-TW', 'zh-HK')) {
        Write-Fixture $translation ('{"menu":"' + $lang + '","oldKey":"old"}')
        Assert-Equal (Install-DesktopCatalog $resources $translation $lang) $true 'Packed mode selected'
        $data = [IO.File]::ReadAllBytes($asar)
        $parsed = Read-AsarHeader $data $asar
        foreach ($name in @('en-US.json', "$lang.json")) {
            $entry = $parsed.Header.files.resources.files.i18n.files.$name
            $text = Get-AsarCatalogText $data $parsed.HeaderSize $entry
            $catalog = $text | ConvertFrom-Json
            Assert-Equal $catalog.menu $lang 'Packed catalog locale'
            Assert-Equal $catalog.newKey 'New version {name}' 'Packed catalog retains new key'
            Assert-Equal $entry.integrity.hash (Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($text))) 'Catalog hash'
            Assert-Equal $entry.integrity.blocks[0] $entry.integrity.hash 'Catalog block hash'
        }
        foreach ($name in @('index.js', 'native.node', 'alias')) {
            Assert-Equal ($parsed.Header.files.$name | ConvertTo-Json -Compress -Depth 10) ($originalHeader.files.$name | ConvertTo-Json -Compress -Depth 10) "Unmodified metadata: $name"
        }
        Assert-Equal (Get-AsarCatalogText $data $parsed.HeaderSize $parsed.Header.files.'index.js') 'console.log("untouched");' 'Main JS payload unchanged'
        $exeText = [IO.File]::ReadAllText($exe)
        if (-not $exeText.Contains((Get-AsarHeaderHash $asar))) { throw 'EXE hash not synchronized' }
        $hash = (Get-FileHash $asar).Hash
        Install-DesktopCatalog $resources $translation $lang | Out-Null
        Assert-Equal (Get-FileHash $asar).Hash $hash 'Repeated patch does not grow the archive'
    }
    Restore-LatestBackup $resources
    Assert-Equal (Get-FileHash $asar).Hash $originalAsar 'Packed catalog restored byte-for-byte'
    Assert-Equal (Get-FileHash $exe).Hash $originalExe 'EXE restored byte-for-byte'
    $invalid = $false
    try { Get-AsarCatalogText ([byte[]]::new(20)) 8 ([pscustomobject]@{size=8;offset='9'}) | Out-Null }
    catch { $invalid = $true }
    if (-not $invalid) { throw 'Invalid entry bounds accepted' }

    # Exercise real catalog files with the issue's keys, not just synthetic translations.
    foreach ($lang in @('zh-CN', 'zh-TW', 'zh-HK')) {
        $pack = Get-LanguageResources $lang
        $catalog = Merge-TranslationCatalog '{"Yrtr74Rv+h":"For your toughest challenges","new-id":"Most capable for ambitious work","unknown":"Keep {name}"}' $pack.Frontend $pack.FrontendHardcoded | ConvertFrom-Json
        if ($catalog.'Yrtr74Rv+h' -eq 'For your toughest challenges' -or $catalog.'new-id' -eq 'Most capable for ambitious work') { throw "Missing model translation: $lang" }
        Assert-Equal $catalog.unknown 'Keep {name}' 'Unknown message preserved with real pack'
    }

    $env:LOCALAPPDATA = Join-Path $temp 'profile\Local'
    $env:APPDATA = Join-Path $temp 'profile\Roaming'
    function Get-ClaudeAppxPackages { return @([pscustomobject]@{PackageFamilyName='Claude_test'}) }
    $paths = @(Get-ClaudeConfigPaths)
    $localConfig = Join-Path $env:LOCALAPPDATA 'Claude-3p\config.json'
    $msixConfig = Join-Path $env:LOCALAPPDATA 'Packages\Claude_test\LocalCache\Local\Claude-3p\config.json'
    if ($paths -notcontains $localConfig -or $paths -notcontains $msixConfig) { throw 'Missing LocalAppData config paths' }
    Write-Fixture $localConfig '{"locale":"en-US","keep":"untouched"}'
    Set-ClaudeLocale 'zh-CN'
    Assert-Equal (Read-Catalog $localConfig).locale 'zh-CN' 'Real userData layout updated'
    Assert-Equal (Read-Catalog $localConfig).keep 'untouched' 'Other config fields preserved'
    Write-Host 'PASS: issue #223 catalog fallback, layouts, models, backups, integrity, and config paths.' -ForegroundColor Green
}
finally {
    $env:LOCALAPPDATA = $oldLocal
    $env:APPDATA = $oldRoaming
    $resolved = [IO.Path]::GetFullPath($temp)
    if ($resolved.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like '.tmp-i18n-*' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
