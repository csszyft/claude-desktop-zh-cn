param([Parameter(Mandatory = $true)][string[]]$FunctionNames)
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\load_windows_functions.ps1') -FunctionNames $FunctionNames
