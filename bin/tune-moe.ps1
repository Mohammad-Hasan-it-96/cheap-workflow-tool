# NOTE 2026-09-14: local stack removed; needs llama.cpp + a model to run.
# tune-moe.ps1  -- rev2, uses llama-bench (purpose-built) instead of parsing llama-cli
#
# IMPORTANT: stop llama-server first. The sweep needs the whole 4 GB to itself.
#   Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
#
# pp = prompt processing (prefill) tok/s  -> the number that decides agent-loop speed
# tg = text generation tok/s              -> how fast it writes code
param(
    [string]$Model  = "D:\ai\models\gpt-oss-20b-F16.gguf",
    [string]$Values = "24,22,20,18,16",   # gpt-oss-20b = 24 layers. Qwen3-30B = 48,44,40,36,32
    [string]$KvType = "q8_0",             # f16 to compare; q8_0 frees ~750 MB at 32k ctx
    [int]$Reps      = 2
)

if (Get-Process llama-server -ErrorAction SilentlyContinue) {
    throw "llama-server is RUNNING. Stop it first or every config will OOM."
}

& "D:\ai\llama.cpp\llama-bench.exe" `
    -m $Model `
    -ncmoe $Values `
    -ngl 99 `
    -t 6 `
    -ctk $KvType -ctv $KvType `
    -p 2048 -n 64 `
    -r $Reps `
    --progress `
    -o md
