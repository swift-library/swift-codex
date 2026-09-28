param(
  [ValidateSet('debug', 'release')]
  [string] $Configuration = 'debug',
  [string] $LogDirectory = ''
)

$ErrorActionPreference = 'Stop'
if (!$LogDirectory) { $LogDirectory = Join-Path $PSScriptRoot '.build/fixture-logs' }
New-Item -ItemType Directory -Force $LogDirectory | Out-Null
$swiftLog = Join-Path $LogDirectory "$Configuration-fixture.log"
$nativeLog = Join-Path $LogDirectory "$Configuration-environment-fixture.log"
swift build --package-path $PSScriptRoot --product CodexProcessFixture -c $Configuration *> $swiftLog
if ($LASTEXITCODE -ne 0) { Get-Content $swiftLog -Tail 60; exit $LASTEXITCODE }

$binaryDirectory = swift build --package-path $PSScriptRoot -c $Configuration --show-bin-path
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$source = Join-Path $PSScriptRoot 'EnvironmentFixture/main.c'
$executable = Join-Path $binaryDirectory 'CodexEnvironmentFixture.exe'
# Build the Win32 fixture with the C toolchain so it has no Swift runtime dependency.
clang $source -o $executable -lkernel32 *> $nativeLog
if ($LASTEXITCODE -ne 0) { Get-Content $nativeLog -Tail 60; exit $LASTEXITCODE }
