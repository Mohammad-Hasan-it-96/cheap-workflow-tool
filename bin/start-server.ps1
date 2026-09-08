# start-server.ps1
# Usage:  .\start-server.ps1                    -> safe defaults
#         .\start-server.ps1 -NCpuMoe 18 -Ctx 65536
param(
    [int]$NCpuMoe = 24,        # gpt-oss-20b has 24 layers; 24 = all experts on CPU
    [int]$Ctx     = 65536,     # MEASURED 2026-09-07: fits at 3489/4096 MiB with q8_0 KV
    [string]$Model = "D:\ai\models\gpt-oss-20b-F16.gguf",
    [string]$Alias = "gpt-oss-20b",
    [switch]$NoQuantKV         # q8_0 KV is ON by default; pass -NoQuantKV to use f16
)

$Bin = "D:\ai\llama.cpp\llama-server.exe"
if (-not (Test-Path $Bin))   { throw "llama-server.exe not found. Run install-llamacpp.ps1 first." }
if (-not (Test-Path $Model)) { throw "Model not found: $Model" }

# Not named $args: that is an automatic PowerShell variable.
$serverArgs = @(
    "-m", $Model,
    "--alias", $Alias,
    "--n-cpu-moe", $NCpuMoe,   # keep MoE experts of N layers on CPU
    "-ngl", "99",              # offload everything else it can to GPU
    "-c", $Ctx,                # context window
    "-np", "1",                # ONE slot. -np defaults to auto, and the KV pool
                               # is shared across slots - with 2 slots this -c
                               # is split in half and the agent silently gets
                               # 32k, not the 64k measured here.
    "-t", "6",                 # 6 PHYSICAL cores. Do not use 12.
    "--jinja",                 # REQUIRED for tool calling to work
    "--host", "127.0.0.1",
    "--port", "8080",
    "--metrics"
)
if (-not $NoQuantKV) { $serverArgs += @("--cache-type-k", "q8_0", "--cache-type-v", "q8_0") }

Write-Host "Launching: $Bin $($serverArgs -join ' ')`n"
& $Bin @serverArgs
