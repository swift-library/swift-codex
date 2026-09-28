param([string]$OutputDirectory = '.build/mcp-http-candidate')

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$metadata = Get-Content (Join-Path $PSScriptRoot 'upstream.json') -Raw | ConvertFrom-Json
$patch = Join-Path $PSScriptRoot 'eventsource-availability.patch'
if ((Get-FileHash $patch -Algorithm SHA256).Hash.ToLowerInvariant() -ne $metadata.patchSHA256) {
    throw 'Dependency candidate patch checksum mismatch'
}
$output = Join-Path $repository $OutputDirectory
if (Test-Path $output) { throw 'Use a fresh candidate output directory' }
New-Item -ItemType Directory -Path $output | Out-Null
$output = (Resolve-Path $output).Path
$source = Join-Path $output 'swift-sdk'
$consumer = Join-Path $output 'consumer'
$evidence = Join-Path $output 'evidence'
New-Item -ItemType Directory -Path $consumer, $evidence | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'upstream.json') $evidence
Copy-Item $patch $evidence
swift --version | Out-File (Join-Path $evidence 'toolchain.txt')
if ($LASTEXITCODE -ne 0) { throw 'Swift toolchain unavailable' }

git -c core.autocrlf=false clone --no-checkout $metadata.repository $source
if ($LASTEXITCODE -ne 0) { throw 'Upstream clone failed' }
git -C $source checkout --detach $metadata.revision
if ($LASTEXITCODE -ne 0) { throw 'Upstream checkout failed' }
$revision = git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision -ne $metadata.revision) { throw 'Upstream revision mismatch' }

swift build --package-path $source --target MCP *> (Join-Path $evidence 'unpatched-build.log')
$unpatchedExitCode = $LASTEXITCODE
if ($unpatchedExitCode -eq 0 -or !(Select-String -Path (Join-Path $evidence 'unpatched-build.log') -SimpleMatch "no such module 'EventSource'" -Quiet)) {
    throw 'Unpatched source did not reproduce the EventSource module failure; inspect the build log'
}
git -C $source apply --check $patch
if ($LASTEXITCODE -ne 0) { throw 'Candidate patch does not apply to pinned upstream' }
git -C $source apply $patch
if ($LASTEXITCODE -ne 0) { throw 'Candidate patch application failed' }
git -C $source diff --stat | Out-File (Join-Path $evidence 'source-diff-stat.txt')
git -C $source diff --check
if ($LASTEXITCODE -ne 0) { throw 'Candidate source whitespace check failed' }

Copy-Item (Join-Path $PSScriptRoot 'Package.swift.template') (Join-Path $consumer 'Package.swift')
$testDirectory = Join-Path $consumer 'Tests'
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testSources = @('InMemoryTransportTests.swift')
$testHashes = foreach ($name in $testSources) {
    $original = Join-Path $source "Tests/MCPTests/$name"
    $copy = Join-Path $testDirectory $name
    Copy-Item $original $copy
    $hash = (Get-FileHash $original -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-FileHash $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Test source copy changed' }
    [pscustomobject]@{ path = "Tests/MCPTests/$name"; sha256 = $hash }
}
$testHashes | ConvertTo-Json | Set-Content (Join-Path $evidence 'upstream-test-sources.json')
Copy-Item (Join-Path $PSScriptRoot 'HTTPTransportTests.swift') $testDirectory

$developer = Split-Path (Split-Path $env:SDKROOT.TrimEnd([char[]]'\/'))
$testing = Join-Path $developer 'Library/Testing-6.2.3/usr/bin64'
$xctest = Join-Path $developer 'Library/XCTest-6.2.3/usr/bin64'
if (!(Test-Path (Join-Path $testing 'Testing.dll'))) { throw 'Missing SDK Testing runtime' }
if (!(Test-Path (Join-Path $xctest 'XCTest.dll'))) { throw 'Missing SDK XCTest runtime' }
$env:PATH = "$testing;$xctest;$env:PATH"
$ready = Join-Path $evidence 'http-endpoint.txt'
$server = [System.Diagnostics.Process]::new()
$server.StartInfo.FileName = 'python'
$server.StartInfo.UseShellExecute = $false
$server.StartInfo.RedirectStandardError = $true
$server.StartInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'http_fixture.py'))
$server.StartInfo.ArgumentList.Add('--ready-file')
$server.StartInfo.ArgumentList.Add($ready)
$previousEndpoint = $env:MCP_HTTP_FIXTURE_ENDPOINT
$results = @()
$started = $false
try {
    $started = $server.Start()
    if (!$started) { throw 'HTTP fixture failed to start' }
    $startup = [System.Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path $ready)) {
        if ($server.HasExited -or $startup.Elapsed.TotalSeconds -gt 10) { throw 'HTTP fixture was not ready' }
        Start-Sleep -Milliseconds 20
    }
    $env:MCP_HTTP_FIXTURE_ENDPOINT = Get-Content $ready -Raw
    foreach ($configuration in @('debug', 'release')) {
        $log = Join-Path $evidence "$configuration-tests.log"
        swift test --package-path $consumer --no-parallel -c $configuration *> $log
        $testCode = $LASTEXITCODE
        Get-Content $log -Tail 60
        $results += [pscustomobject]@{ configuration = $configuration; testExitCode = $testCode }
        [pscustomobject]@{ unpatchedBuildExitCode = $unpatchedExitCode; patchedResults = $results } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'results.json')
    }
} finally {
    $env:MCP_HTTP_FIXTURE_ENDPOINT = $previousEndpoint
    if ($started -and !$server.HasExited) { $server.Kill() }
    if ($started) {
        if (!$server.WaitForExit(5000)) { throw 'Owned HTTP fixture did not exit' }
        $server.StandardError.ReadToEnd() | Out-File (Join-Path $evidence 'http-server-stderr.log')
    }
    $server.Dispose()
}
if (Test-Path (Join-Path $consumer 'Package.resolved')) {
    Copy-Item (Join-Path $consumer 'Package.resolved') (Join-Path $evidence 'consumer-Package.resolved')
}
if (Test-Path (Join-Path $source 'Package.resolved')) {
    Copy-Item (Join-Path $source 'Package.resolved') (Join-Path $evidence 'upstream-Package.resolved')
}
if ($results.Where({ $_.testExitCode -ne 0 }).Count -gt 0) { exit 1 }
