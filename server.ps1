<#
    FMCG Shop — Enterprise Cloud Operations & Governance Server (V2)
    Port: 4040
    Inspired by: Oracle WebLogic Admin Console + AWS Systems Manager / CloudWatch
#>

$ErrorActionPreference = "SilentlyContinue"

$PORT = 4040
$HTML_FILE = Join-Path $PSScriptRoot "index.html"
$ENV_FILE = Join-Path $PSScriptRoot ".env"

# Load secrets from backend .env
if (Test-Path $ENV_FILE) {
    Get-Content $ENV_FILE | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}

# Render API Keys from Environment
$ACC1_KEY     = if ($env:RENDER_ACC1_KEY) { $env:RENDER_ACC1_KEY } else { "rnd_RGwnc0JnFnTrKcrO6YAUMg1MHAMl" }
$BACKEND_SVC  = "srv-db141g60tbcc739djhi0"

$ACC2_KEY     = if ($env:RENDER_ACC2_KEY) { $env:RENDER_ACC2_KEY } else { "rnd_Ds6kefykRNVDdJ5ka2Gyf7hNkD2j" }
$WHATSAPP_SVC = "srv-dbodrlrm8hqs7389qlmg"
$OCR_SVC      = "srv-dbodrlrm8hqs7389qlkg"

# Service Endpoints
$WHATSAPP_URL = "https://laritraders-whatsapp.onrender.com"
$OCR_URL      = "https://laritraders-ocr.onrender.com"
$BACKEND_URL  = "https://laritraders-backend.onrender.com"
$INTERNAL_SEC = "lari-wa-internal-secret-uat-2024"

# Neon PostgreSQL connection test endpoint via Spring Boot Actuator
$NEON_HEALTH_URL = "$BACKEND_URL/actuator/health"

# Stop any existing listener on port 4040
try {
    $existing = Get-NetTCPConnection -LocalPort $PORT -ErrorAction SilentlyContinue
    if ($existing) {
        $pids = $existing | Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($p in $pids) {
            if ($p -ne $PID) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        }
    }
} catch {}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$PORT/")
$listener.Start()

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " 🏛️ FMCG Enterprise Cloud Console (V2) running at:" -ForegroundColor Yellow
Write-Host "    http://localhost:$PORT" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

function Send-Json($response, $obj, $statusCode = 200) {
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Admin-Pin")
    $json = $obj | ConvertTo-Json -Depth 6
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

function Send-Html($response, $filePath) {
    if (Test-Path $filePath) {
        $response.StatusCode = 200
        $response.ContentType = "text/html; charset=utf-8"
        $buffer = [System.IO.File]::ReadAllBytes($filePath)
        $response.ContentLength64 = $buffer.Length
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
    } else {
        $response.StatusCode = 404
    }
    $response.OutputStream.Close()
}

function Get-ServiceInfo($svcKey) {
    switch ($svcKey) {
        "backend"  { return @{ Key = $ACC1_KEY; SvcId = $BACKEND_SVC;  Name = "laritraders-backend";  Account = "Account 1 (Dedicated)" } }
        "wa"       { return @{ Key = $ACC2_KEY; SvcId = $WHATSAPP_SVC; Name = "laritraders-whatsapp"; Account = "Account 2 (Microservices)" } }
        "ocr"      { return @{ Key = $ACC2_KEY; SvcId = $OCR_SVC;      Name = "laritraders-ocr";      Account = "Account 2 (Microservices)" } }
        default    { return $null }
    }
}

try {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            $urlPath = $request.Url.AbsolutePath
            $method = $request.HttpMethod

        if ($method -eq "OPTIONS") {
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Admin-Pin")
            $response.StatusCode = 200
            $response.OutputStream.Close()
            continue
        }

        # ── Serve Dashboard UI ──
        if ($urlPath -eq "/" -or $urlPath -eq "/index.html") {
            Send-Html $response $HTML_FILE
            continue
        }

        # ── API: Status & Deep Observability Matrix ──
        if ($urlPath -eq "/api/status" -and $method -eq "GET") {
            $dayOfMonth = (Get-Date).Day
            $daysInMonth = [DateTime]::DaysInMonth((Get-Date).Year, (Get-Date).Month)
            
            # Acc 1 Quota (Backend 24/7)
            $acc1HoursUsed = [math]::Min(750, $dayOfMonth * 24)
            $acc1HoursRemain = [math]::Max(0, 750 - $acc1HoursUsed)
            $acc1Percent = [math]::Round(($acc1HoursUsed / 750) * 100, 1)

            # Acc 2 Quota (Microservices)
            $acc2HoursUsed = 12
            $acc2HoursRemain = 738
            $acc2Percent = [math]::Round(($acc2HoursUsed / 750) * 100, 1)

            # Burn Rate Projection
            $hoursLeftInMonth = ($daysInMonth - $dayOfMonth) * 24
            $projectedAcc1 = $acc1HoursUsed + $hoursLeftInMonth
            $acc1Safe = $projectedAcc1 -le 750

            # 1. Ping Backend Latency & Health
            $backendLatency = -1
            $backendStatus = "Down"
            $dbStatus = "Unknown"
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $res = Invoke-RestMethod -Uri "$BACKEND_URL/actuator/health" -TimeoutSec 4
                $sw.Stop()
                $backendLatency = [math]::Round($sw.ElapsedMilliseconds)
                $backendStatus = if ($res.status -eq "UP") { "Live" } else { "Degraded" }
                $dbStatus = "Connected"
            } catch {
                $backendStatus = "Down"
                $dbStatus = "Unreachable"
            }

            # 2. Ping WhatsApp Microservice
            $waLatency = -1
            $waStatus = "DISCONNECTED"
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $res = Invoke-RestMethod -Uri "$WHATSAPP_URL/status" -TimeoutSec 4
                $sw.Stop()
                $waLatency = [math]::Round($sw.ElapsedMilliseconds)
                $waStatus = if ($res.status) { $res.status } else { "DISCONNECTED" }
            } catch {
                $waStatus = "Down"
            }

            # 3. Ping OCR Microservice
            $ocrLatency = -1
            $ocrStatus = "Down"
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $res = Invoke-RestMethod -Uri "$OCR_URL/health" -TimeoutSec 6
                $sw.Stop()
                $ocrLatency = [math]::Round($sw.ElapsedMilliseconds)
                $ocrStatus = if ($res.status -eq "UP" -or $res.status -eq "healthy") { "Healthy" } else { "Active" }
            } catch {
                $ocrStatus = "Down"
            }

            # 4. Service Suspension States from Render API
            $h2 = @{ Authorization = "Bearer $ACC2_KEY" }
            $h1 = @{ Authorization = "Bearer $ACC1_KEY" }
            $waSuspended = $false
            $ocrSuspended = $false
            $backendSuspended = $false
            try {
                $sWa = Invoke-RestMethod -Uri "https://api.render.com/v1/services/$WHATSAPP_SVC" -Headers $h2
                $waSuspended = ($sWa.suspended -eq "suspended")
                $sOcr = Invoke-RestMethod -Uri "https://api.render.com/v1/services/$OCR_SVC" -Headers $h2
                $ocrSuspended = ($sOcr.suspended -eq "suspended")
                $sBackend = Invoke-RestMethod -Uri "https://api.render.com/v1/services/$BACKEND_SVC" -Headers $h1
                $backendSuspended = ($sBackend.suspended -eq "suspended")
            } catch {}

            $payload = @{
                quota = @{
                    acc1 = @{
                        hoursUsed   = $acc1HoursUsed
                        hoursRemain = $acc1HoursRemain
                        percent     = $acc1Percent
                        safe        = $acc1Safe
                        projected   = $projectedAcc1
                    }
                    acc2 = @{
                        hoursUsed   = $acc2HoursUsed
                        hoursRemain = $acc2HoursRemain
                        percent     = $acc2Percent
                        safe        = $true
                    }
                }
                services = @{
                    backend = @{
                        id        = $BACKEND_SVC
                        name      = "laritraders-backend"
                        account   = "Account 1 (Dedicated)"
                        status    = $backendStatus
                        latency   = $backendLatency
                        suspended = $backendSuspended
                        url       = $BACKEND_URL
                        dbStatus  = $dbStatus
                    }
                    whatsapp = @{
                        id        = $WHATSAPP_SVC
                        name      = "laritraders-whatsapp"
                        account   = "Account 2 (Microservices)"
                        status    = $waStatus
                        latency   = $waLatency
                        suspended = $waSuspended
                        url       = $WHATSAPP_URL
                    }
                    ocr = @{
                        id        = $OCR_SVC
                        name      = "laritraders-ocr"
                        account   = "Account 2 (Microservices)"
                        status    = $ocrStatus
                        latency   = $ocrLatency
                        suspended = $ocrSuspended
                        url       = $OCR_URL
                    }
                }
            }

            Send-Json $response $payload
            continue
        }

        # ── API: Trigger Deploy (With optional clearCache) ──
        if ($urlPath -eq "/api/deploy" -and $method -eq "POST") {
            $svcParam = $request.QueryString["service"]
            $clearCache = if ($request.QueryString["clearCache"] -eq "true") { "clear" } else { "do_not_clear" }
            $info = Get-ServiceInfo $svcParam

            if (-not $info) {
                Send-Json $response @{ success = $false; error = "Invalid service specified" } 400
                continue
            }

            try {
                $h = @{
                    "Authorization" = "Bearer $($info.Key)"
                    "Content-Type"  = "application/json"
                }
                $b = @{ clearCache = $clearCache } | ConvertTo-Json
                $dep = Invoke-RestMethod -Uri "https://api.render.com/v1/services/$($info.SvcId)/deploys" -Method Post -Headers $h -Body $b
                Send-Json $response @{ success = $true; deployId = $dep.id; status = $dep.status }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        # ── API: Restart Service ──
        if ($urlPath -eq "/api/restart" -and $method -eq "POST") {
            $svcParam = $request.QueryString["service"]
            $info = Get-ServiceInfo $svcParam

            if (-not $info) {
                Send-Json $response @{ success = $false; error = "Invalid service specified" } 400
                continue
            }

            try {
                $h = @{
                    "Authorization" = "Bearer $($info.Key)"
                    "Content-Type"  = "application/json"
                }
                Invoke-RestMethod -Uri "https://api.render.com/v1/services/$($info.SvcId)/restart" -Method Post -Headers $h -Body "{}" | Out-Null
                Send-Json $response @{ success = $true; message = "$($info.Name) restarted successfully" }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        # ── API: Suspend Service (Scale-to-Zero) ──
        if ($urlPath -eq "/api/suspend" -and $method -eq "POST") {
            $svcParam = $request.QueryString["service"]
            $info = Get-ServiceInfo $svcParam

            if (-not $info) {
                Send-Json $response @{ success = $false; error = "Invalid service specified" } 400
                continue
            }

            try {
                $h = @{
                    "Authorization" = "Bearer $($info.Key)"
                    "Content-Type"  = "application/json"
                }
                Invoke-RestMethod -Uri "https://api.render.com/v1/services/$($info.SvcId)/suspend" -Method Post -Headers $h -Body "{}" | Out-Null
                Send-Json $response @{ success = $true; message = "$($info.Name) suspended (0 hours consuming now)" }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        # ── API: Resume Service ──
        if ($urlPath -eq "/api/resume" -and $method -eq "POST") {
            $svcParam = $request.QueryString["service"]
            $info = Get-ServiceInfo $svcParam

            if (-not $info) {
                Send-Json $response @{ success = $false; error = "Invalid service specified" } 400
                continue
            }

            try {
                $h = @{
                    "Authorization" = "Bearer $($info.Key)"
                    "Content-Type"  = "application/json"
                }
                Invoke-RestMethod -Uri "https://api.render.com/v1/services/$($info.SvcId)/resume" -Method Post -Headers $h -Body "{}" | Out-Null
                Send-Json $response @{ success = $true; message = "$($info.Name) resumed and waking up" }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        # ── API: Get Audit Events (Deployments & Logs) ──
        if ($urlPath -eq "/api/events" -and $method -eq "GET") {
            $svcParam = if ($request.QueryString["service"]) { $request.QueryString["service"] } else { "backend" }
            $info = Get-ServiceInfo $svcParam

            if (-not $info) {
                Send-Json $response @{ success = $false; error = "Invalid service specified" } 400
                continue
            }

            try {
                $h = @{ Authorization = "Bearer $($info.Key)" }
                $eventsRaw = Invoke-RestMethod -Uri "https://api.render.com/v1/services/$($info.SvcId)/events?limit=8" -Headers $h
                $eventList = @()
                foreach ($item in $eventsRaw) {
                    $ev = $item.event
                    $eventList += @{
                        id        = $ev.id
                        type      = $ev.type
                        timestamp = $ev.timestamp
                        details   = $ev.details
                    }
                }
                Send-Json $response @{ success = $true; service = $info.Name; events = $eventList }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        # ── API: Test Gemini AI Prompt ──
        if ($urlPath -eq "/api/test-ai" -and $method -eq "POST") {
            $reader = New-Object System.IO.StreamReader($request.InputStream)
            $reqBodyRaw = $reader.ReadToEnd()
            $reqJson = $reqBodyRaw | ConvertFrom-Json
            $promptText = if ($reqJson.prompt) { $reqJson.prompt } else { "Explain automated FMCG inventory management in 2 sentences." }

            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $h = @{
                    "Content-Type"      = "application/json"
                    "X-Internal-Secret" = $INTERNAL_SEC
                }
                $b = @{ prompt = $promptText } | ConvertTo-Json
                $aiRes = Invoke-RestMethod -Uri "$OCR_URL/ocr/generate-text" -Method Post -Headers $h -Body $b -TimeoutSec 15
                $sw.Stop()
                $elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                Send-Json $response @{ success = $true; text = $aiRes.text; elapsed = $elapsedSec; model = "gemini-2.5-flash" }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        # ── API: Test WhatsApp Echo/Ping ──
        if ($urlPath -eq "/api/test-wa" -and $method -eq "POST") {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $res = Invoke-RestMethod -Uri "$WHATSAPP_URL/status" -TimeoutSec 5
                $sw.Stop()
                Send-Json $response @{ success = $true; status = $res.status; elapsed = $sw.ElapsedMilliseconds }
            } catch {
                Send-Json $response @{ success = $false; error = $_.Exception.Message } 500
            }
            continue
        }

        $response.StatusCode = 404
        $response.OutputStream.Close()
    } catch {
        Write-Host "Request handling error: $_"
    }
}
} finally {
    $listener.Stop()
    $listener.Close()
}
