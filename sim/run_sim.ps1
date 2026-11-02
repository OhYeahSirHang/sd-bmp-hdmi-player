# Run the three verification testbenches and save logs.
$ErrorActionPreference = "Stop"
$VivadoBin = "D:\Xilinx\Vivado\2022.2\bin"
$root      = Split-Path $PSScriptRoot -Parent
$work      = Join-Path $PSScriptRoot "work"
$results   = Join-Path $PSScriptRoot "results"
New-Item -ItemType Directory -Force $work, $results | Out-Null
Set-Location $work

function Run-Test($name, $tbFile, $dutFiles, $logName) {
    Write-Host "=== $name ==="
    & (Join-Path $VivadoBin "xvlog.bat") @dutFiles $tbFile | Out-Null
    & (Join-Path $VivadoBin "xelab.bat") -debug typical $name -s $name | Out-Null
    & (Join-Path $VivadoBin "xsim.bat") $name -runall |
        Out-File -Encoding utf8 (Join-Path $results $logName)
    Get-Content (Join-Path $results $logName) -Tail 8
}

$rtl = Join-Path $root "src\rtl"

Run-Test "tb_fps_15" `
    (Join-Path $PSScriptRoot "tb\tb_fps_15.v") `
    @((Join-Path $rtl "new\vid_player.v")) `
    "fps15_result.log"

Run-Test "tb_sd_multi" `
    (Join-Path $PSScriptRoot "tb\tb_sd_multi.v") `
    @((Join-Path $rtl "sd_ctrl\sd_rd.v")) `
    "sd_multi_result.log"

Run-Test "tb_sd_single" `
    (Join-Path $PSScriptRoot "tb\tb_sd_single.v") `
    @((Join-Path $rtl "sd_ctrl\sd_rd.v")) `
    "sd_single_result.log"

Write-Host "Done. Logs: $results"
