param([string]$OutputDirectory = '.build/mcp-transport-candidate')

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$metadata = Get-Content (Join-Path $PSScriptRoot 'upstream.json') -Raw | ConvertFrom-Json
$patch = Join-Path $PSScriptRoot 'windows-transports.patch'
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
$testSources = @('InMemoryTransportTests.swift', 'WindowsStdioTransportTests.swift')
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
$previousPath = $env:PATH
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
        if ($server.HasExited -or $startup.Elapsed.TotalSeconds -gt 10) {
            [pscustomobject]@{
                hasExited = $server.HasExited
                exitCode = $(if ($server.HasExited) { $server.ExitCode } else { $null })
                elapsedMilliseconds = $startup.ElapsedMilliseconds
            } | ConvertTo-Json | Set-Content (Join-Path $evidence 'http-startup-failure.json')
            throw 'HTTP fixture was not ready'
        }
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
    $env:PATH = $previousPath
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

# Archive the complete exact SDK source into a disposable candidate tree.
# SwiftPM may update this consumer's lock for local packages; the shipping lock is untouched.
$sdkRevision = git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify CodexMCP candidate source' }
$sdkSource = Join-Path $output 'sdk-source'
$ownerConsumer = Join-Path $output 'codex-mcp-consumer'
New-Item -ItemType Directory -Path $sdkSource, $ownerConsumer | Out-Null
$sdkArchive = Join-Path $output 'sdk-source.tar'
git -C $repository archive --format=tar --output=$sdkArchive $sdkRevision
if ($LASTEXITCODE -ne 0) { throw 'SDK source archive failed' }
tar -xf $sdkArchive -C $sdkSource
if ($LASTEXITCODE -ne 0) { throw 'SDK source extraction failed' }
$shippingLock = Join-Path $repository 'Package.resolved'
$shippingLockHash = (Get-FileHash $shippingLock -Algorithm SHA256).Hash
Copy-Item $shippingLock (Join-Path $evidence 'sdk-shipping-Package.resolved')
Copy-Item $shippingLock (Join-Path $ownerConsumer 'Package.resolved')
Copy-Item (Join-Path $PSScriptRoot 'CodexMCPPackage.swift.template') (Join-Path $ownerConsumer 'Package.swift')
$ownerTests = Join-Path $ownerConsumer 'Tests'
New-Item -ItemType Directory -Path $ownerTests | Out-Null
$testSource = Join-Path $sdkSource 'Tests/CodexMCPTests/CodexMCPRealBinaryIntegrationTests.swift'
$testCopy = Join-Path $ownerTests 'CodexMCPRealBinaryIntegrationTests.swift'
Copy-Item $testSource $testCopy
$testHash = (Get-FileHash $testSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-FileHash $testCopy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $testHash) {
    throw 'CodexMCP real-binary test source changed'
}

$binaryMetadataPath = Join-Path $PSScriptRoot 'codex-windows-binary.json'
$binaryMetadata = Get-Content $binaryMetadataPath -Raw | ConvertFrom-Json
Copy-Item $binaryMetadataPath $evidence
$binaryDirectory = Join-Path $output 'codex-binary'
New-Item -ItemType Directory -Path $binaryDirectory | Out-Null
$binaryArchive = Join-Path $binaryDirectory 'codex.zip'
Invoke-WebRequest -Uri $binaryMetadata.archiveURL -OutFile $binaryArchive
if ((Get-FileHash $binaryArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $binaryMetadata.archiveSHA256) {
    throw 'Codex release archive checksum mismatch'
}
Expand-Archive -Path $binaryArchive -DestinationPath $binaryDirectory
$binary = Join-Path $binaryDirectory $binaryMetadata.executable
if ((Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant() -ne $binaryMetadata.executableSHA256) {
    throw 'Codex native binary checksum mismatch'
}
$version = & $binary --version
if ($LASTEXITCODE -ne 0 -or $version -ne "codex-cli $($binaryMetadata.version)") {
    throw 'Unexpected native Codex version'
}
$version | Set-Content (Join-Path $evidence 'codex-version.txt')
& $binary mcp-server --help *> (Join-Path $evidence 'codex-mcp-help.txt')
if ($LASTEXITCODE -ne 0) { throw 'Pinned Codex does not expose mcp-server' }

$previousEnabled = $env:SWIFT_CODEX_REAL_BINARY_TESTS
$previousBinary = $env:SWIFT_CODEX_REAL_BINARY_PATH
$env:SWIFT_CODEX_REAL_BINARY_TESTS = '1'
$env:SWIFT_CODEX_REAL_BINARY_PATH = $binary
$env:PATH = "$testing;$xctest;$previousPath"
$ownerResults = @()
try {
    foreach ($configuration in @('debug', 'release')) {
        $log = Join-Path $evidence "codex-mcp-$configuration-tests.log"
        # Preserve the owning tests' internal startup-metadata assertions in this external consumer.
        swift test --package-path $ownerConsumer --no-parallel -c $configuration -Xswiftc -enable-testing *> $log
        $code = $LASTEXITCODE
        Get-Content $log -Tail 60
        $ownerResults += [pscustomobject]@{ configuration = $configuration; testExitCode = $code }
        [pscustomobject]@{
            sdkRevision = $sdkRevision
            sdkSourceArchiveSHA256 = (Get-FileHash $sdkArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            mcpCandidate = $metadata
            binary = $binaryMetadata
            testSource = 'Tests/CodexMCPTests/CodexMCPRealBinaryIntegrationTests.swift'
            testSourceSHA256 = $testHash
            results = $ownerResults
            evidenceClass = 'complete-native-product-real-cli-protocol-lifecycle'
            authenticatedModel = $false
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $evidence 'codex-mcp-runtime-results.json')
    }
} finally {
    $env:SWIFT_CODEX_REAL_BINARY_TESTS = $previousEnabled
    $env:SWIFT_CODEX_REAL_BINARY_PATH = $previousBinary
    $env:PATH = $previousPath
    $candidateLock = Join-Path $ownerConsumer 'Package.resolved'
    if (Test-Path $candidateLock) { Copy-Item $candidateLock (Join-Path $evidence 'codex-mcp-consumer-Package.resolved') }
    if ((Get-FileHash $shippingLock -Algorithm SHA256).Hash -ne $shippingLockHash) {
        throw 'SDK shipping dependency lock changed'
    }
}
if ($ownerResults.Where({ $_.testExitCode -ne 0 }).Count -gt 0) { exit 1 }
