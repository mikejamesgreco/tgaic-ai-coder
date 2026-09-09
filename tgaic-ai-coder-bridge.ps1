param(
  [string]$ListenHost = "127.0.0.1",
  [int]$ListenPort = 8787,
  [string]$UpstreamBase = "http://127.0.0.1:8080/v1"
)

$ErrorActionPreference = "Stop"

$UpstreamRoot = $UpstreamBase -replace "/v1/?$", ""
$HuggingFaceBase = "https://huggingface.co"
$HfDebug = $true
$HfToken = $env:HF_TOKEN

# Windows PowerShell 5.1 does not always preload System.Net.Http.
# Explicitly load it before constructing HttpClient/HttpClientHandler.
Add-Type -AssemblyName System.Net.Http

function Add-CorsHeaders {
  param($Response)
  $Response.Headers["Access-Control-Allow-Origin"] = "*"
  $Response.Headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-HF-Token"
  $Response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  $Response.Headers["Cache-Control"] = "no-store"
}

function Write-Json {
  param($Response, $Object, [int]$StatusCode = 200)
  $json = $Object | ConvertTo-Json -Depth 10 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = "application/json; charset=utf-8"
  Add-CorsHeaders $Response
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.OutputStream.Close()
}





function New-HfRequest {
  param(
    [string]$Url,
    [string]$RequestToken
  )

  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)

  # Token entered in the HTML page takes precedence for this request.
  # Fall back to the bridge process HF_TOKEN environment variable.
  $effectiveToken = $null
  if ($RequestToken -and $RequestToken.Trim().Length -gt 0) {
    $effectiveToken = $RequestToken.Trim()
  }
  elseif ($HfToken -and $HfToken.Trim().Length -gt 0) {
    $effectiveToken = $HfToken.Trim()
  }

  if ($effectiveToken) {
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $effectiveToken)
  }

  # Friendly user agent for Hugging Face API traffic.
  try {
    $req.Headers.UserAgent.ParseAdd("TGAIC/1.0")
  } catch {}

  return $req
}

function Write-HfDebug {
  param([string]$Message)
  if ($HfDebug) {
    Write-Host "[HF DEBUG] $Message" -ForegroundColor Cyan
  }
}

function Get-TextPreview {
  param([string]$Text, [int]$MaxLength = 600)
  if ($null -eq $Text) { return "" }
  $clean = $Text -replace "`r", " " -replace "`n", " "
  if ($clean.Length -le $MaxLength) { return $clean }
  return $clean.Substring(0, $MaxLength) + "..."
}

function Get-QueryInt {
  param($Request, [string]$Name, [int]$Default, [int]$Min, [int]$Max)
  $raw = $Request.QueryString[$Name]
  $n = $Default
  if ($raw) {
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed)) { $n = $parsed }
  }
  if ($n -lt $Min) { $n = $Min }
  if ($n -gt $Max) { $n = $Max }
  return $n
}

function Get-GgufQuant {
  param([string]$FileName)
  $upper = [IO.Path]::GetFileNameWithoutExtension($FileName).ToUpperInvariant()
  $patterns = @("IQ[1-4]_[A-Z0-9_]+","Q[2-8]_[A-Z0-9_]+","F16","F32","BF16")
  foreach ($pattern in $patterns) {
    $m = [regex]::Match($upper, "(?<![A-Z0-9])($pattern)(?![A-Z0-9])")
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return "GGUF"
}


function Test-HfSizeFilter {
  param(
    [int64]$Bytes,
    [string]$Filter
  )

  if (-not $Filter) { return $true }
  if ($Bytes -le 0) { return $false }

  $gb = [double]$Bytes / 1GB
  switch ($Filter) {
    "0-1"   { return ($gb -lt 1) }
    "1-2"   { return ($gb -ge 1 -and $gb -lt 2) }
    "2-4"   { return ($gb -ge 2 -and $gb -lt 4) }
    "4-8"   { return ($gb -ge 4 -and $gb -lt 8) }
    "8-16"  { return ($gb -ge 8 -and $gb -lt 16) }
    "16-32" { return ($gb -ge 16 -and $gb -lt 32) }
    "32+"   { return ($gb -ge 32) }
    default { return $true }
  }
}

function Invoke-HuggingFaceModelSearch {
  param($Request)

  $search = [string]$Request.QueryString["search"]
  $pageSize = Get-QueryInt $Request "limit" 10 1 100

  $sort = [string]$Request.QueryString["sort"]
  if (-not $sort) { $sort = "downloads" }

  # Supported by Hugging Face list_models / models API.
  $allowedSorts = @("created_at","downloads","last_modified","likes","trending_score")
  if ($allowedSorts -notcontains $sort) {
    throw "Unsupported Hugging Face sort: $sort"
  }

  $quantFilter = [string]$Request.QueryString["quant"]
  $sizeFilter = [string]$Request.QueryString["size"]
  $typeFilter = [string]$Request.QueryString["type"]
  if (-not $typeFilter) { $typeFilter = "" }
  if (@("","text","multimodal") -notcontains $typeFilter) {
    throw "Unsupported model type filter: $typeFilter"
  }
  $requestHfToken = [string]$Request.Headers["X-HF-Token"]

  # A TGAIC page is result-oriented. The Hub API may return many non-GGUF
  # repos, so this bridge keeps consuming Hub pages until it has collected
  # pageSize matching GGUF repositories or the Hub search is exhausted.
  #
  # We fetch candidate batches larger than the visible TGAIC page to reduce
  # Hub list-request count. A cursor offset lets the next TGAIC page resume
  # inside the same Hub batch without skipping unconsumed candidates.
  $hubBatchSize = [Math]::Min(100, [Math]::Max(50, $pageSize * 5))

  $cursorUrl = [string]$Request.QueryString["cursorUrl"]
  if (-not $cursorUrl) {
    # Backward compatibility with v0025 HTML.
    $cursorUrl = [string]$Request.QueryString["pageUrl"]
  }
  $cursorOffset = Get-QueryInt $Request "cursorOffset" 0 0 1000000

  if ($cursorUrl) {
    if (-not $cursorUrl.StartsWith("$HuggingFaceBase/api/models?", [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Invalid Hugging Face pagination cursor URL."
    }
    $listUrl = $cursorUrl
  }
  else {
    $parts = @("sort=$([Uri]::EscapeDataString($sort))","limit=$hubBatchSize","full=true")
    if ($search) { $parts += "search=$([Uri]::EscapeDataString($search))" }
    $listUrl = "$HuggingFaceBase/api/models?" + ($parts -join "&")
    $cursorOffset = 0
  }

  $results = New-Object System.Collections.Generic.List[object]
  $sourceRepoCount = 0
  $ggufCandidateCount = 0
  $treeInspectionCount = 0
  $treeInspectionSuccessCount = 0
  $hubPagesFetched = 0
  $searchExhausted = $false
  $nextCursorUrl = $null
  $nextCursorOffset = 0
  $firstHubQuery = $listUrl

  while ($results.Count -lt $pageSize -and $listUrl) {
    $hubPagesFetched++
    Write-HfDebug "SEARCH PAGE $hubPagesFetched URL: $listUrl"
    Write-HfDebug "SEARCH PAGE START OFFSET: $cursorOffset"

    $listReq = New-HfRequest $listUrl $requestHfToken
    $listResp = $client.SendAsync($listReq).GetAwaiter().GetResult()
    $listJson = $listResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    Write-HfDebug "SEARCH STATUS: $([int]$listResp.StatusCode) $($listResp.ReasonPhrase)"
    Write-HfDebug "SEARCH BODY LENGTH: $($listJson.Length)"
    Write-HfDebug "SEARCH BODY PREVIEW: $(Get-TextPreview $listJson)"

    if (-not $listResp.IsSuccessStatusCode) {
      throw "Hugging Face search returned HTTP $([int]$listResp.StatusCode) $($listResp.ReasonPhrase): $(Get-TextPreview $listJson)"
    }

    $nextHubUrl = $null
    $linkValues = $null
    if ($listResp.Headers.TryGetValues("Link", [ref]$linkValues)) {
      $linkHeader = ($linkValues -join ",")
      Write-HfDebug "SEARCH LINK HEADER: $linkHeader"
      $nextMatch = [regex]::Match(
        $linkHeader,
        '<([^>]+)>\s*;\s*rel="?next"?',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      if ($nextMatch.Success) {
        $nextHubUrl = $nextMatch.Groups[1].Value
        Write-HfDebug "SEARCH NEXT HUB URL: $nextHubUrl"
      }
    }
    else {
      Write-HfDebug "SEARCH LINK HEADER: <none>"
    }

    # Explicit enumeration for Windows PowerShell 5.1 top-level JSON arrays.
    $parsedRepos = ConvertFrom-Json -InputObject $listJson
    $repoList = New-Object System.Collections.Generic.List[object]
    foreach ($parsedRepo in $parsedRepos) {
      $repoList.Add($parsedRepo)
    }
    $repos = $repoList.ToArray()
    $sourceRepoCount += $repos.Count

    Write-HfDebug "SEARCH PARSED REPO COUNT: $($repos.Count)"

    if ($repos.Count -eq 0) {
      if ($nextHubUrl) {
        $listUrl = $nextHubUrl
        $cursorOffset = 0
        continue
      }
      $searchExhausted = $true
      break
    }

    if ($cursorOffset -ge $repos.Count) {
      if ($nextHubUrl) {
        $listUrl = $nextHubUrl
        $cursorOffset = 0
        continue
      }
      $searchExhausted = $true
      break
    }

    $stoppedForFullPage = $false

    for ($i = $cursorOffset; $i -lt $repos.Count; $i++) {
      $repo = $repos[$i]
      if (-not $repo.id) { continue }

      $isGgufCandidate = $false
      if ($repo.tags) {
        foreach ($tag in $repo.tags) {
          if (([string]$tag).ToLowerInvariant() -eq "gguf") {
            $isGgufCandidate = $true
            break
          }
        }
      }
      if (-not $isGgufCandidate) {
        if (([string]$repo.id) -match '(?i)(^|[-_/])GGUF($|[-_/])') {
          $isGgufCandidate = $true
        }
      }
      if (-not $isGgufCandidate) { continue }

      $ggufCandidateCount++
      $treeInspectionCount++

      try {
        $repoIdEscaped = ($repo.id -split "/" | ForEach-Object { [Uri]::EscapeDataString($_) }) -join "/"
        $treeUrl = "$HuggingFaceBase/api/models/$repoIdEscaped/tree/main?recursive=true"

        Write-HfDebug "TREE REPO: $($repo.id)"
        $treeReq = New-HfRequest $treeUrl $requestHfToken
        $treeResp = $client.SendAsync($treeReq).GetAwaiter().GetResult()
        $treeJson = $treeResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        Write-HfDebug "TREE STATUS: $([int]$treeResp.StatusCode) $($treeResp.ReasonPhrase)"

        if (-not $treeResp.IsSuccessStatusCode) {
          Write-HfDebug "TREE SKIPPED DUE TO HTTP ERROR: $(Get-TextPreview $treeJson 250)"
          continue
        }

        $parsedTree = ConvertFrom-Json -InputObject $treeJson
        $treeList = New-Object System.Collections.Generic.List[object]
        foreach ($parsedTreeItem in $parsedTree) {
          $treeList.Add($parsedTreeItem)
        }
        $tree = $treeList.ToArray()
        $treeInspectionSuccessCount++

        $ggufFiles = New-Object System.Collections.Generic.List[object]
        $hasMmproj = $false
        $hasMtp = $false
        foreach ($s in $tree) {
          if ([string]$s.type -ne "file") { continue }

          $name = [string]$s.path
          if (-not $name -or -not $name.ToLowerInvariant().EndsWith(".gguf")) { continue }

          $leaf = [IO.Path]::GetFileName($name).ToLowerInvariant()
          if ($leaf.StartsWith("mmproj-")) {
            $hasMmproj = $true
            continue
          }
          if ($leaf.StartsWith("mtp-")) {
            $hasMtp = $true
            continue
          }

          $size = 0L
          if ($null -ne $s.size) {
            try { $size = [int64]$s.size } catch {}
          }
          if ($size -le 0 -and $null -ne $s.lfs -and $null -ne $s.lfs.size) {
            try { $size = [int64]$s.lfs.size } catch {}
          }

          $ggufFiles.Add([pscustomobject]@{
            file = $name
            size = $size
            quant = Get-GgufQuant $name
          })
        }

        if ($ggufFiles.Count -eq 0) { continue }

        # Current TGAIC is text-chat only. Repositories containing an mmproj
        # are treated as multimodal for discovery purposes so they can be
        # excluded by default before we count toward the requested page size.
        $modelType = $(if ($hasMmproj) { "multimodal" } else { "text" })
        if ($typeFilter -eq "text" -and $modelType -ne "text") { continue }
        if ($typeFilter -eq "multimodal" -and $modelType -ne "multimodal") { continue }

        # Compatibility is intentionally advisory, not a promise. Tree shape
        # can identify companion files, but it cannot prove that a converted
        # GGUF matches the exact tensor expectations of the installed build.
        $compatibilityLevel = "info"
        if ($hasMmproj) {
          $compatibility = "Multimodal · mmproj companion"
          $compatibilityLevel = "warn"
        }
        elseif (([string]$repo.id) -match '(?i)qwen[._-]?3[._-]?5|qwen3\.5') {
          $compatibility = "Text GGUF · Qwen3.5: verify llama.cpp build/conversion"
          $compatibilityLevel = "warn"
        }
        elseif ($hasMtp) {
          $compatibility = "Text GGUF · optional MTP sidecar present"
        }
        else {
          $compatibility = "Text GGUF · no companion file detected"
        }

        $rawFiles = $ggufFiles.ToArray()

        # Collapse multiple files/shards that represent the same quantization
        # into one logical choice. This prevents a single repository from
        # rendering as multiple rows for the same Q4_K_M (etc.) and makes the
        # displayed page count line up with the requested page size.
        $quantGroups = @{}
        foreach ($rf in $rawFiles) {
          $q = [string]$rf.quant
          if (-not $q) { $q = "GGUF" }

          if (-not $quantGroups.ContainsKey($q)) {
            $quantGroups[$q] = [pscustomobject]@{
              file = [string]$rf.file
              size = [int64]0
              quant = $q
              shardCount = 0
            }
          }

          $g = $quantGroups[$q]
          try { $g.size = [int64]$g.size + [int64]$rf.size } catch {}
          $g.shardCount = [int]$g.shardCount + 1
        }

        $fileList = New-Object System.Collections.Generic.List[object]
        foreach ($qKey in ($quantGroups.Keys | Sort-Object)) {
          $g = $quantGroups[$qKey]
          if ($g.shardCount -gt 1) {
            $g.file = "$($g.file) (+$($g.shardCount - 1) shard(s))"
          }
          $fileList.Add($g)
        }
        $files = $fileList.ToArray()

        # Match the HTML's preferred-quant behavior closely enough that a size
        # filter can participate in filling the TGAIC page. With a requested
        # quant, use that file when present and otherwise fall back to the first
        # GGUF file, as the HTML does. With "All quantizations", any file that
        # satisfies the size filter makes the repository eligible.
        $repoMatches = $false

        if ($quantFilter) {
          $selectedFile = $null
          foreach ($f in $files) {
            if ([string]$f.quant -eq $quantFilter) {
              $selectedFile = $f
              break
            }
          }
          if (-not $selectedFile -and $files.Count -gt 0) {
            $selectedFile = $files[0]
          }

          if ($selectedFile) {
            $repoMatches = Test-HfSizeFilter ([int64]$selectedFile.size) $sizeFilter
          }
        }
        else {
          foreach ($f in $files) {
            if (Test-HfSizeFilter ([int64]$f.size) $sizeFilter) {
              $repoMatches = $true
              break
            }
          }
        }

        if (-not $repoMatches) { continue }

        $results.Add([pscustomobject]@{
          id = [string]$repo.id
          downloads = $(if ($null -ne $repo.downloads) { [int64]$repo.downloads } else { 0 })
          likes = $(if ($null -ne $repo.likes) { [int64]$repo.likes } else { 0 })
          lastModified = $(if ($repo.lastModified) { [string]$repo.lastModified } else { $null })
          url = "$HuggingFaceBase/$($repo.id)"
          modelType = $modelType
          compatibility = $compatibility
          compatibilityLevel = $compatibilityLevel
          hasMmproj = [bool]$hasMmproj
          hasMtp = [bool]$hasMtp
          ggufFiles = $files
        })

        Write-HfDebug "MATCH $($results.Count)/${pageSize}: $($repo.id)"

        if ($results.Count -ge $pageSize) {
          # Resume exactly after the repo just consumed. If there are more
          # repos in this same Hub batch, remember this URL plus an item offset.
          # Otherwise continue at Hugging Face's next page URL.
          if (($i + 1) -lt $repos.Count) {
            $nextCursorUrl = $listUrl
            $nextCursorOffset = $i + 1
          }
          elseif ($nextHubUrl) {
            $nextCursorUrl = $nextHubUrl
            $nextCursorOffset = 0
          }

          $stoppedForFullPage = $true
          break
        }
      }
      catch {
        Write-Warning "Hugging Face repo inspection failed for $($repo.id): $($_.Exception.Message)"
        Write-HfDebug "TREE EXCEPTION TYPE: $($_.Exception.GetType().FullName)"
      }
    }

    if ($stoppedForFullPage) {
      break
    }

    # Current Hub batch is exhausted but the TGAIC page is not full yet.
    if ($nextHubUrl) {
      $listUrl = $nextHubUrl
      $cursorOffset = 0
    }
    else {
      $searchExhausted = $true
      $listUrl = $null
    }
  }

  if (-not $nextCursorUrl -and -not $searchExhausted -and $results.Count -lt $pageSize) {
    $searchExhausted = $true
  }

  Write-HfDebug "SUMMARY: requested=$pageSize, returned=$($results.Count), hubPages=$hubPagesFetched, sourceRepos=$sourceRepoCount, ggufCandidates=$ggufCandidateCount, treeAttempts=$treeInspectionCount, treeSuccess=$treeInspectionSuccessCount, exhausted=$searchExhausted"

  return [pscustomobject]@{
    ok = $true
    search = $search
    sort = $sort
    requestedPageSize = $pageSize
    quantFilter = $quantFilter
    sizeFilter = $sizeFilter
    typeFilter = $typeFilter
    hubQuery = $firstHubQuery
    nextCursorUrl = $nextCursorUrl
    nextCursorOffset = $nextCursorOffset
    hasNextPage = [bool]$nextCursorUrl
    searchExhausted = $searchExhausted
    hubPagesFetched = $hubPagesFetched
    appliedFilter = "GGUF metadata prefilter + repo-tree verification + active quant/size/type filter + companion-file compatibility hints"
    sourceRepoCount = $sourceRepoCount
    ggufCandidateCount = $ggufCandidateCount
    treeInspectionCount = $treeInspectionCount
    treeInspectionSuccessCount = $treeInspectionSuccessCount
    ggufRepoCount = $results.Count
    count = $results.Count
    debugEnabled = $HfDebug
    hfAuthMode = $(if ($requestHfToken -and $requestHfToken.Trim().Length -gt 0) { "HTML token" } elseif ($HfToken -and $HfToken.Trim().Length -gt 0) { "environment token" } else { "anonymous" })
    data = $results.ToArray()
  }
}
$prefix = "http://${ListenHost}:${ListenPort}/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
$script:ShutdownRequested = $false

$handler = [System.Net.Http.HttpClientHandler]::new()
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromHours(12)

Write-Host ""
Write-Host "TGAIC AI Coder Bridge"
Write-Host "Listening : $prefix"
Write-Host "Upstream  : $UpstreamBase"
Write-Host "HF Search : $HuggingFaceBase/api/models"
Write-Host "HF Debug  : $HfDebug"
Write-Host "HF Token  : $(if ($HfToken -and $HfToken.Trim().Length -gt 0) { 'Environment token configured' } else { 'No environment token (HTML token supported)' })"
Write-Host "Mode      : API bridge only (open the TGAIC HTML file directly)"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

try {
  while ($listener.IsListening -and -not $script:ShutdownRequested) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    try {
      Add-CorsHeaders $res

      if ($req.HttpMethod -eq "OPTIONS") {
        $res.StatusCode = 204
        $res.Close()
        continue
      }

      $path = $req.Url.AbsolutePath

      if ($path -eq "/") {
        Write-Json $res @{
          ok = $true
          bridge = "TGAIC AI Coder Bridge"
          mode = "api-proxy"
          message = "Open the TGAIC HTML directly; use /health, /v1/*, /models*, or /hf/models for API access."
          upstream = $UpstreamBase
          huggingFace = "$HuggingFaceBase/api/models"
        }
        continue
      }


      if ($path -eq "/shutdown" -and $req.HttpMethod -eq "POST") {
        Write-Json $res @{
          ok = $true
          bridge = "TGAIC AI Coder Bridge"
          message = "Bridge shutdown requested"
        }
        $script:ShutdownRequested = $true
        continue
      }

      if ($path -eq "/health") {
        Write-Json $res @{
          ok = $true
          bridge = "TGAIC AI Coder Bridge"
          mode = "api-proxy"
          cors = "allow-all"
          upstream = $UpstreamBase
        }
        continue
      }


      if ($path -eq "/hf/models" -and $req.HttpMethod -eq "GET") {
        try {
          $hf = Invoke-HuggingFaceModelSearch $req
          Write-Json $res $hf
        }
        catch {
          Write-Json $res @{
            ok = $false
            error = $_.Exception.Message
            exceptionType = $_.Exception.GetType().FullName
            message = "Hugging Face model search or repo-tree inspection failed"
          } 502
        }
        continue
      }

      # OpenAI-compatible calls are exposed by the bridge under /v1/*.
      # llama.cpp router model-management calls live at root-level /models*.
      if ($path.StartsWith("/v1/")) {
        $upstreamPath = $path.Substring(3)  # remove /v1, keep leading /
        $target = $UpstreamBase.TrimEnd("/") + $upstreamPath + $req.Url.Query
      }
      elseif ($path -eq "/models" -or $path.StartsWith("/models/")) {
        $target = $UpstreamRoot.TrimEnd("/") + $path + $req.Url.Query
      }
      else {
        Write-Json $res @{ error = "Use /health, /v1/*, /models*, or /hf/models" } 404
        continue
      }

      $method = [System.Net.Http.HttpMethod]::new($req.HttpMethod)
      $message = [System.Net.Http.HttpRequestMessage]::new($method, $target)

      if ($req.HasEntityBody) {
        $reader = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
        $body = $reader.ReadToEnd()
        $reader.Dispose()
        $message.Content = [System.Net.Http.StringContent]::new(
          $body,
          [Text.Encoding]::UTF8,
          $(if ($req.ContentType) { $req.ContentType.Split(";")[0] } else { "application/json" })
        )
      }

      if ($req.Headers["Authorization"]) {
        $message.Headers.TryAddWithoutValidation("Authorization", $req.Headers["Authorization"]) | Out-Null
      }

      # ResponseHeadersRead preserves SSE/token streaming from llama.cpp and similar servers.
      $up = $client.SendAsync(
        $message,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
      ).GetAwaiter().GetResult()

      $res.StatusCode = [int]$up.StatusCode
      $contentType = $up.Content.Headers.ContentType
      if ($contentType) {
        $res.ContentType = $contentType.ToString()
      } else {
        $res.ContentType = "application/octet-stream"
      }

      # Copy useful upstream headers, but never let the upstream server
      # overwrite the bridge's browser/CORS contract. In particular,
      # llama.cpp may emit its own Access-Control-* headers; a blank or
      # malformed value here breaks file:// -> localhost requests in Edge.
      foreach ($h in $up.Headers) {
        if ($h.Key -notin @(
          "Transfer-Encoding",
          "Connection",
          "Access-Control-Allow-Origin",
          "Access-Control-Allow-Headers",
          "Access-Control-Allow-Methods",
          "Access-Control-Expose-Headers",
          "Access-Control-Max-Age",
          "Access-Control-Allow-Credentials"
        )) {
          try { $res.Headers[$h.Key] = ($h.Value -join ",") } catch {}
        }
      }

      # Reassert the bridge-owned CORS headers after upstream headers are copied.
      Add-CorsHeaders $res

      $stream = $up.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $buffer = New-Object byte[] 16384
      try {
        while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
          $res.OutputStream.Write($buffer, 0, $n)
          $res.OutputStream.Flush()
        }
      } finally {
        $stream.Dispose()
        $up.Dispose()
        $message.Dispose()
        $res.OutputStream.Close()
      }
    }
    catch {
      try {
        if ($res.OutputStream.CanWrite) {
          Write-Json $res @{ error = $_.Exception.Message } 502
        }
      } catch {}
      Write-Warning $_.Exception.Message
    }
  }
}
finally {
  if ($listener.IsListening) { $listener.Stop() }
  $listener.Close()
  $client.Dispose()
}
