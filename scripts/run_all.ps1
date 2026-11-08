# 教务系统接口性能测试 - 批量执行脚本
# 用法：powershell -File scripts\run_all.ps1
#   可选参数：-Duration 30 -Ramp 5 -Threads "10,50,100"
param(
    [int]$Duration = 30,
    [int]$Ramp = 5,
    [string]$Threads = "10,50,100",
    [string]$BaseUrl = "http://localhost:8082/api",
    [string]$JmeterHome = "D:\apache-jmeter-5.6.3"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$Jmeter = Join-Path $JmeterHome "bin\jmeter.bat"
if (-not (Test-Path -LiteralPath $Jmeter)) {
    throw "未找到 JMeter：$Jmeter，请修改 -JmeterHome 参数"
}

$ThreadList = $Threads -split "," | ForEach-Object { [int]$_.Trim() }
$ResultsDir = Join-Path $Root "results"
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
$SummaryFile = Join-Path $ResultsDir "summary.csv"
"scenario,threads,duration,samples,tps,avg_ms,min_ms,max_ms,p50_ms,p90_ms,p95_ms,p99_ms,error_rate,report_dir" |
    Out-File -LiteralPath $SummaryFile -Encoding utf8

function Invoke-JMeterScenario {
    param([string]$Jmx, [int]$Concurrency, [string]$Tag, [string]$Token)

    $Jtl = Join-Path $ResultsDir "$Tag.jtl"
    $Log = Join-Path $ResultsDir "$Tag.log"
    $OutDir = Join-Path $ResultsDir "html\$Tag"

    Remove-Item -LiteralPath $Jtl, $Log -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutDir) | Out-Null

    $ArgList = @(
        "-n", "-t", $Jmx,
        "-Jthreads=$Concurrency", "-Jramp=$Ramp", "-Jduration=$Duration",
        "-l", $Jtl, "-j", $Log,
        "-e", "-o", $OutDir
    )
    if ($Token) { $ArgList += "-Jtoken=$Token" }

    & $Jmeter @ArgList *> (Join-Path $ResultsDir "$Tag.out.txt")

    if (-not (Test-Path -LiteralPath $Jtl)) { throw "压测未产出 jtl：$Tag" }

    $Rows = Get-Content -LiteralPath $Jtl | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne "" }
    $Elapsed = @()
    $Fail = 0
    foreach ($Row in $Rows) {
        $Parts = $Row -split ","
        if ($Parts.Count -lt 9) { continue }
        $Elapsed += [int]$Parts[1]
        if ($Parts[7] -eq "false") { $Fail++ }
    }
    if ($Elapsed.Count -eq 0) { throw "jtl 无有效样本：$Tag" }

    $Sorted = $Elapsed | Sort-Object
    function Pct([double]$p) {
        $idx = [Math]::Floor(($Sorted.Count - 1) * $p)
        return $Sorted[[int]$idx]
    }
    $Sum = ($Elapsed | Measure-Object -Sum).Sum
    $Avg = [Math]::Round($Sum / $Elapsed.Count, 1)
    $Tps = [Math]::Round($Elapsed.Count / $Duration, 2)
    $ErrRate = [Math]::Round($Fail * 100.0 / $Elapsed.Count, 2)

    $Csv = "$Tag,$Concurrency,$Duration,$($Elapsed.Count),$Tps,$Avg,$($Sorted[0]),$($Sorted[-1]),$(Pct 0.50),$(Pct 0.90),$(Pct 0.95),$(Pct 0.99),$ErrRate,results/html/$Tag"
    Add-Content -LiteralPath $SummaryFile -Value $Csv -Encoding utf8
    Write-Host ("[OK] $Tag  samples=$($Elapsed.Count)  tps=$Tps  avg=${Avg}ms  p95=$(Pct 0.95)ms  err=$ErrRate%")
}

Write-Host "=== 场景一：登录接口（BCrypt CPU 密集）==="
foreach ($t in $ThreadList) {
    Invoke-JMeterScenario -Jmx (Join-Path $Root "jmx\login_stress.jmx") -Concurrency $t -Tag "login_$t"
}

Write-Host "=== 重新登录取 token ==="
$LoginBody = '{"username":"admin","password":"admin123"}'
$LoginResp = Invoke-RestMethod -Uri "$BaseUrl/auth/login" -Method POST -Body $LoginBody -ContentType "application/json" -TimeoutSec 10
$Token = $LoginResp.data.token
if (-not $Token) { throw "登录取 token 失败" }
Write-Host ("token len = " + $Token.Length)

Write-Host "=== 场景二：核心查询接口 ==="
foreach ($t in $ThreadList) {
    Invoke-JMeterScenario -Jmx (Join-Path $Root "jmx\query_stress.jmx") -Concurrency $t -Tag "query_$t" -Token $Token
}

Write-Host "=== 完成，汇总见 results\summary.csv ==="
Get-Content -LiteralPath $SummaryFile -Encoding utf8
