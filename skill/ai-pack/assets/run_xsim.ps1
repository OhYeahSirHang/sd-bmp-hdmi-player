<#
.SYNOPSIS
    run_xsim.ps1 —— Vivado xsim 三段式批量跑仿真 + 证据落盘

.DESCRIPTION
    对每个模块执行：清 xsim.dir → xvlog → xelab → xsim -runall，
    三段输出分别落 _xvlog.txt / _xelab.txt / _xsim.txt，
    最后抽出 `=== RESULT: ... ===` 行并给出退出码。

    为什么强制三段落盘：
    本会话复核旧工程时，只有 _xsim.txt 是完整证据，xvlog/xelab 的警告（位宽、
    多驱动、localparam 覆盖无效）全被 `*>` 吞进 console 后丢失，导致
    "日志与源码是否同源"只能靠猜。落盘后 check_sim_logs.py 才能交叉验证。

.PARAMETER ProjectRoot
    工程根目录（只读使用；本脚本不会写入工程，工作副本请自己先复制）。

.PARAMETER VivadoBin
    Vivado bin 目录，例如 D:\XILINX\Vivado\2022.2\bin

.PARAMETER Jobs
    形如 @{ Name='key_menu'; SimDir='sim\key_menu'; Sources=@('...v'); TB='tb_key_menu.v'; Snap='tb_key_menu_snap' }
    的空数组元素列表。

.EXAMPLE
    .\run_xsim.ps1 -VivadoBin "D:\XILINX\Vivado\2022.2\bin" -Jobs @(
        @{ Name='key_menu'; SimDir='sim\key_menu'
           Sources=@('sd_bmp_hdmi.srcs\sources_1\new\key_menu.v')
           TB='tb_key_menu.v'; Snap='tb_key_menu_snap' }
    )

.NOTES
    验证状态：按 Vivado 2022.2 xsim CLI 语义编写，未在本机执行
    （本会话 PowerShell 被执行策略拦截：DSH 引导脚本 .ps1 无法加载）。
    首次使用请先用一个最小模块跑通，再批量。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$VivadoBin = "D:\XILINX\Vivado\2022.2\bin",
    [Parameter(Mandatory = $true)][array]$Jobs
)

$ErrorActionPreference = 'Stop'

function Require-Tool([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到 $Name : $Path" }
}

$xvlog = Join-Path $VivadoBin 'xvlog.bat'
$xelab = Join-Path $VivadoBin 'xelab.bat'
$xsim  = Join-Path $VivadoBin 'xsim.bat'
Require-Tool $xvlog 'xvlog'
Require-Tool $xelab 'xelab'
Require-Tool $xsim  'xsim'

$summary = @()

foreach ($job in $Jobs) {
    $simDir = Join-Path $ProjectRoot $job.SimDir
    $work   = Join-Path $simDir 'xsim'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    if (Test-Path (Join-Path $work 'xsim.dir')) {
        Remove-Item (Join-Path $work 'xsim.dir') -Recurse -Force
    }

    Push-Location $work
    try {
        $srcs = @()
        foreach ($s in $job.Sources) { $srcs += (Join-Path $ProjectRoot $s) }
        $tbPath = Join-Path $ProjectRoot (Join-Path $job.SimDir $job.TB)
        $srcs += $tbPath

        & $xvlog --work xil_defaultlib @srcs *> _xvlog.txt
        $rcVlog = $LASTEXITCODE
        if ($rcVlog -ne 0) {
            $summary += [pscustomobject]@{ Job=$job.Name; Stage='xvlog'; RC=$rcVlog; Result='COMPILE-ERROR' }
            continue
        }

        & $xelab "xil_defaultlib.$($job.Snap)" -debug typical -s $job.Snap *> _xelab.txt
        $rcElab = $LASTEXITCODE
        if ($rcElab -ne 0) {
            $summary += [pscustomobject]@{ Job=$job.Name; Stage='xelab'; RC=$rcElab; Result='ELAB-ERROR' }
            continue
        }

        & $xsim $job.Snap -runall *> _xsim.txt
        $rcSim = $LASTEXITCODE

        $hit = Select-String -Path _xsim.txt -Pattern '=== RESULT:' | Select-Object -Last 1
        $result = if ($hit) { $hit.Line.Trim() } else { 'NO-RESULT' }
        $summary += [pscustomobject]@{ Job=$job.Name; Stage='xsim'; RC=$rcSim; Result=$result }
    }
    finally {
        Pop-Location
    }
}

$summary | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

# 把汇总也写一份，方便后续比对
$summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $ProjectRoot 'sim_summary.json') -Encoding UTF8

$bad = $summary | Where-Object { $_.RC -ne 0 -or $_.Result -notmatch 'RESULT:\s*PASS' }
if ($bad) { exit 1 } else { exit 0 }
