param([string]$OutputDirectory = '.build/windows-mcp')

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$output = Join-Path $repository $OutputDirectory
if (Test-Path $output) { throw 'Use a fresh validation output directory' }
New-Item -ItemType Directory -Path $output | Out-Null
$output = (Resolve-Path $output).Path
$evidence = Join-Path $output 'evidence'
New-Item -ItemType Directory -Path $evidence | Out-Null
swift --version | Out-File (Join-Path $evidence 'toolchain.txt')
if ($LASTEXITCODE -ne 0) { throw 'Swift toolchain unavailable' }
git -C $repository diff --quiet HEAD -- Package.swift Package.resolved Sources Tests/WindowsMCP Tests/CodexMCPTests
if ($LASTEXITCODE -ne 0) { throw 'Commit the SDK validation inputs before archiving them' }

# The consumer uses an exact SDK source archive and the SDK's versioned dependency graph.
$sdkRevision = git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify SDK source' }
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
$shippingPins = (Get-Content $shippingLock -Raw | ConvertFrom-Json).pins
$mcpPin = @($shippingPins | Where-Object { $_.identity -eq 'swift-sdk' })
if ($mcpPin.Count -ne 1 -or $mcpPin[0].location -ne 'https://github.com/computer-mcp/swift-sdk.git' -or !$mcpPin[0].state.version) {
    throw 'The SDK must pin its versioned MCP transport dependency'
}
Copy-Item (Join-Path $PSScriptRoot 'Package.swift.template') (Join-Path $ownerConsumer 'Package.swift')
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

swift package --package-path $ownerConsumer resolve *> (Join-Path $evidence 'resolve.log')
if ($LASTEXITCODE -ne 0) { throw 'CodexMCP consumer resolution failed' }
$consumerLock = Join-Path $ownerConsumer 'Package.resolved'
$resolvedPins = (Get-Content $consumerLock -Raw | ConvertFrom-Json).pins
foreach ($pin in $resolvedPins) {
    $expected = @($shippingPins | Where-Object { $_.identity -eq $pin.identity })
    if ($expected.Count -ne 1 -or $expected[0].location -ne $pin.location -or
        $expected[0].state.version -ne $pin.state.version -or
        $expected[0].state.revision -ne $pin.state.revision) {
        throw "Consumer dependency differs from the SDK shipping lock: $($pin.identity)"
    }
}
if (@($resolvedPins | Where-Object { $_.identity -eq 'swift-sdk' }).Count -ne 1) {
    throw 'The CodexMCP consumer did not resolve its MCP dependency'
}

$developer = Split-Path (Split-Path $env:SDKROOT.TrimEnd([char[]]'\/'))
$testing = Join-Path $developer 'Library/Testing-6.2.3/usr/bin64'
$xctest = Join-Path $developer 'Library/XCTest-6.2.3/usr/bin64'
if (!(Test-Path (Join-Path $testing 'Testing.dll'))) { throw 'Missing SDK Testing runtime' }
if (!(Test-Path (Join-Path $xctest 'XCTest.dll'))) { throw 'Missing SDK XCTest runtime' }
$previousPath = $env:PATH
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
        swift test --package-path $ownerConsumer --disable-automatic-resolution --no-parallel -c $configuration -Xswiftc -enable-testing *> $log
        $code = $LASTEXITCODE
        Get-Content $log -Tail 60
        $ownerResults += [pscustomobject]@{ configuration = $configuration; testExitCode = $code }
        [pscustomobject]@{
            sdkRevision = $sdkRevision
            sdkSourceArchiveSHA256 = (Get-FileHash $sdkArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            mcpDependency = $mcpPin[0]
            shippingLockSHA256 = $shippingLockHash.ToLowerInvariant()
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
    if (Test-Path $consumerLock) { Copy-Item $consumerLock (Join-Path $evidence 'codex-mcp-consumer-Package.resolved') }
    if ((Get-FileHash $shippingLock -Algorithm SHA256).Hash -ne $shippingLockHash) {
        throw 'SDK shipping dependency lock changed'
    }
}
if ($ownerResults.Where({ $_.testExitCode -ne 0 }).Count -gt 0) { exit 1 }
