# 01-install-llamacpp.ps1
# Downloads the newest llama.cpp Windows CUDA 12.4 build + CUDA runtime DLLs.
$ErrorActionPreference = "Stop"

$Dest = "D:\ai\llama.cpp"
$Tmp  = "D:\ai\_tmp"
New-Item -ItemType Directory -Force -Path $Dest, $Tmp | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$hdr = @{ "User-Agent" = "llamacpp-setup" }

Write-Host "Querying GitHub for the latest build that ships a win-cuda-12.4 asset..."
$releases = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15" -Headers $hdr

$binAsset = $null
$rtAsset  = $null
foreach ($r in $releases) {
    $b = $r.assets | Where-Object { $_.name -like "llama-*-bin-win-cuda-12.4-x64.zip" } | Select-Object -First 1
    if ($b) {
        $binAsset = $b
        $rtAsset  = $r.assets | Where-Object { $_.name -like "cudart-llama-bin-win-cuda-12.4-x64.zip" } | Select-Object -First 1
        Write-Host "Found release: $($r.tag_name)"
        break
    }
}
if (-not $binAsset) { throw "No win-cuda-12.4 asset found in the last 15 releases." }
if (-not $rtAsset)  { throw "Binaries found but cudart runtime zip is missing in that release." }

foreach ($a in @($binAsset, $rtAsset)) {
    $out = Join-Path $Tmp $a.name
    Write-Host "Downloading $($a.name) ..."
    # curl.exe is far faster than Invoke-WebRequest for large files
    curl.exe -L --fail --progress-bar -o $out $a.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $($a.name)" }
    Write-Host "Extracting $($a.name) ..."
    Expand-Archive -Path $out -DestinationPath $Dest -Force
}

Write-Host ""
Write-Host "Done. Verifying:"
& "$Dest\llama-server.exe" --version
