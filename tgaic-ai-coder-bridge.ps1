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

# ---------------------------------------------------------------------------
# Local RAG / Reference Index
# ---------------------------------------------------------------------------
# Design boundary:
#   - llama-server owns tokenization via POST /tokenize.
#   - this bridge owns file ingestion, token-sized chunk coordination,
#     metadata, retrieval, and local persistence.
#   - the chat model still owns answer generation.
#
# The index is intentionally stored outside the Git repository so source-code
# reference material is not accidentally committed with the project.
$RagStoreRoot = if ($env:LOCALAPPDATA) {
  Join-Path $env:LOCALAPPDATA "TGAIC"
} else {
  Join-Path $PSScriptRoot ".tgaic-local"
}
$RagStorePath = Join-Path $RagStoreRoot "rag-index.json"

$script:RagIndex = @()
$script:RagMeta = @{
  indexVersion = 1
  createdAt = $null
  fileCount = 0
  chunkCount = 0
  totalTokens = 0
  chunkTargetTokens = 800
  chunkOverlapTokens = 150
  tokenizer = "llama-server /tokenize"
  persistencePath = $RagStorePath
}

function Read-JsonBody {
  param($Request, [int64]$MaxBytes = 52428800)

  if ($Request.ContentLength64 -gt $MaxBytes) {
    throw "Request body is larger than the allowed $MaxBytes bytes."
  }

  $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
  try {
    $body = $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
  }

  if (-not $body -or $body.Trim().Length -eq 0) {
    return $null
  }

  return ConvertFrom-Json -InputObject $body
}

function Invoke-LlamaTokenize {
  param(
    [Parameter(Mandatory=$true)][string]$Content,
    [Parameter(Mandatory=$true)][string]$Model,
    [bool]$WithPieces = $false
  )

  if (-not $Model -or -not $Model.Trim()) {
    throw "A model name is required for llama-server router-mode tokenization."
  }

  $payload = @{
    model = $Model
    content = $Content
    add_special = $false
    parse_special = $true
    with_pieces = $WithPieces
  } | ConvertTo-Json -Compress

  $target = $UpstreamRoot.TrimEnd("/") + "/tokenize"
  $message = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::Post,
    $target
  )
  $message.Content = [System.Net.Http.StringContent]::new(
    $payload,
    [Text.Encoding]::UTF8,
    "application/json"
  )

  try {
    $resp = $client.SendAsync($message).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $resp.IsSuccessStatusCode) {
      throw "llama-server /tokenize returned HTTP $([int]$resp.StatusCode): $(Get-TextPreview $text)"
    }

    return ConvertFrom-Json -InputObject $text
  }
  finally {
    if ($resp) { $resp.Dispose() }
    $message.Dispose()
  }
}

function Convert-TokenPieceToText {
  param($Piece)

  if ($null -eq $Piece) { return "" }
  if ($Piece -is [string]) { return [string]$Piece }

  # llama-server returns raw byte arrays when one token piece is not itself
  # valid Unicode. Convert those bytes locally. Most ordinary source-code
  # pieces arrive as strings.
  try {
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($v in $Piece) {
      $bytes.Add([byte]$v)
    }
    return [Text.Encoding]::UTF8.GetString($bytes.ToArray())
  }
  catch {
    return [string]$Piece
  }
}

function Save-RagIndex {
  try {
    if (-not (Test-Path $RagStoreRoot)) {
      New-Item -ItemType Directory -Path $RagStoreRoot -Force | Out-Null
    }

    $doc = @{
      meta = $script:RagMeta
      chunks = @($script:RagIndex)
    }

    $json = $doc | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($RagStorePath, $json, (New-Object Text.UTF8Encoding($false)))
    return $true
  }
  catch {
    Write-Warning "Could not persist TGAIC RAG index: $($_.Exception.Message)"
    return $false
  }
}

function Load-RagIndex {
  if (-not (Test-Path $RagStorePath)) { return }

  try {
    $raw = [IO.File]::ReadAllText($RagStorePath, [Text.Encoding]::UTF8)
    if (-not $raw) { return }

    $doc = ConvertFrom-Json -InputObject $raw
    if ($doc.meta) {
      foreach ($p in $doc.meta.PSObject.Properties) {
        $script:RagMeta[$p.Name] = $p.Value
      }
    }

    $loaded = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($doc.chunks)) { $loaded.Add($c) }
    $script:RagIndex = $loaded.ToArray()

    Write-Host "RAG Index : loaded $($script:RagIndex.Count) chunk(s) from $RagStorePath"
  }
  catch {
    Write-Warning "Could not load existing TGAIC RAG index: $($_.Exception.Message)"
  }
}

function Clear-RagIndex {
  $script:RagIndex = @()
  $script:RagMeta = @{
    indexVersion = 1
    createdAt = $null
    fileCount = 0
    chunkCount = 0
    totalTokens = 0
    chunkTargetTokens = 800
    chunkOverlapTokens = 150
    tokenizer = "llama-server /tokenize"
    persistencePath = $RagStorePath
  }

  try {
    if (Test-Path $RagStorePath) {
      Remove-Item -Path $RagStorePath -Force
    }
  } catch {}

  return $script:RagMeta
}

function Build-RagIndex {
  param($Payload)

  if (-not $Payload -or -not $Payload.files) {
    throw "RAG index request must contain a files array."
  }

  $model = [string]$Payload.model
  if (-not $model -or -not $model.Trim()) {
    throw "RAG index build requires the selected llama-server model name."
  }

  $targetTokens = 800
  $overlapTokens = 150

  if ($Payload.chunkTargetTokens) { $targetTokens = [int]$Payload.chunkTargetTokens }
  if ($Payload.chunkOverlapTokens -ne $null) { $overlapTokens = [int]$Payload.chunkOverlapTokens }

  if ($targetTokens -lt 128) { $targetTokens = 128 }
  if ($targetTokens -gt 4096) { $targetTokens = 4096 }
  if ($overlapTokens -lt 0) { $overlapTokens = 0 }
  if ($overlapTokens -ge $targetTokens) {
    $overlapTokens = [Math]::Max(0, [int]($targetTokens / 4))
  }

  $files = @($Payload.files)
  if ($files.Count -gt 200) {
    throw "A maximum of 200 reference files can be indexed in one request."
  }

  $chunks = New-Object System.Collections.Generic.List[object]
  $fileCount = 0
  $totalTokens = 0
  $chunkId = 0

  foreach ($file in $files) {
    $name = [string]$file.name
    $text = [string]$file.text

    if (-not $name) { $name = "reference-$($fileCount + 1).txt" }
    if ($null -eq $text -or $text.Length -eq 0) { continue }
    if ($text.Length -gt 15000000) {
      throw "Reference file '$name' is larger than the 15,000,000 character per-file safety limit."
    }

    Write-Host "[RAG] Tokenizing $name ($($text.Length) chars)..."
    $tokenized = Invoke-LlamaTokenize -Content $text -Model $model -WithPieces $true
    $tokens = @($tokenized.tokens)

    if ($tokens.Count -eq 0) { continue }

    $pieceText = New-Object string[] $tokens.Count
    $linePrefix = New-Object int[] ($tokens.Count + 1)
    $linePrefix[0] = 0

    for ($i = 0; $i -lt $tokens.Count; $i++) {
      $piece = $tokens[$i].piece
      $s = Convert-TokenPieceToText $piece
      $pieceText[$i] = $s
      $linePrefix[$i + 1] = $linePrefix[$i] + ([regex]::Matches($s, "`n")).Count
    }

    $step = $targetTokens - $overlapTokens
    if ($step -lt 1) { $step = $targetTokens }

    for ($start = 0; $start -lt $tokens.Count; $start += $step) {
      $end = [Math]::Min($tokens.Count, $start + $targetTokens)
      $sb = New-Object Text.StringBuilder
      for ($j = $start; $j -lt $end; $j++) {
        [void]$sb.Append($pieceText[$j])
      }

      $chunkText = $sb.ToString()
      if (-not $chunkText -or $chunkText.Trim().Length -eq 0) {
        if ($end -ge $tokens.Count) { break }
        continue
      }

      $startLine = $linePrefix[$start] + 1
      $endLine = $linePrefix[$end] + 1
      if ($chunkText.EndsWith("`n") -and $endLine -gt $startLine) {
        $endLine--
      }

      $chunkId++
      $count = $end - $start
      $totalTokens += $count

      $chunks.Add([pscustomobject]@{
        id = $chunkId
        file = $name
        startLine = $startLine
        endLine = $endLine
        tokenStart = $start
        tokenEnd = ($end - 1)
        tokenCount = $count
        text = $chunkText
      })

      if ($end -ge $tokens.Count) { break }
    }

    $fileCount++
  }

  $script:RagIndex = $chunks.ToArray()
  $script:RagMeta = @{
    indexVersion = 1
    createdAt = [DateTime]::UtcNow.ToString("o")
    fileCount = $fileCount
    chunkCount = $script:RagIndex.Count
    totalTokens = $totalTokens
    chunkTargetTokens = $targetTokens
    chunkOverlapTokens = $overlapTokens
    tokenizer = "llama-server /tokenize"
    tokenizerModel = $model
    persistencePath = $RagStorePath
    indexedFiles = @(Get-RagIndexedFiles)
  }

  $persisted = Save-RagIndex

  return @{
    ok = $true
    persisted = $persisted
    meta = $script:RagMeta
  }
}

function Get-RagTerms {
  param([string]$Text)

  $stop = @{
    "the"=1;"and"=1;"that"=1;"this"=1;"with"=1;"from"=1;"into"=1;"where"=1;"what"=1;
    "when"=1;"which"=1;"does"=1;"have"=1;"about"=1;"would"=1;"could"=1;"should"=1;
    "there"=1;"their"=1;"then"=1;"than"=1;"also"=1;"your"=1;"you"=1;"are"=1;"for"=1;
    "how"=1;"why"=1;"who"=1;"can"=1;"use"=1;"used"=1;"using"=1;"get"=1;"set"=1;"was"=1;
    "were"=1;"has"=1;"had"=1;"not"=1;"but"=1;"all"=1;"any"=1;"our"=1;"out"=1
  }

  $seen = @{}
  $terms = New-Object System.Collections.Generic.List[string]
  foreach ($m in [regex]::Matches(($Text.ToLowerInvariant()), "[a-z_][a-z0-9_.$#-]{1,}")) {
    $t = $m.Value
    if ($t.Length -lt 2) { continue }
    if ($stop.ContainsKey($t)) { continue }
    if (-not $seen.ContainsKey($t)) {
      $seen[$t] = $true
      $terms.Add($t)
    }
  }
  return $terms.ToArray()
}

function Search-RagIndex {
  param($Payload)

  if (-not $Payload) { throw "RAG search request body is required." }
  $query = [string]$Payload.query
  if (-not $query.Trim()) { throw "RAG search query is required." }

  $model = [string]$Payload.model
  if (-not $model -or -not $model.Trim()) {
    $model = [string]$script:RagMeta.tokenizerModel
  }
  if (-not $model -or -not $model.Trim()) {
    throw "RAG retrieval requires a llama-server model name."
  }

  $topK = 8
  $budget = 4000
  if ($Payload.topK) { $topK = [int]$Payload.topK }
  if ($Payload.tokenBudget) { $budget = [int]$Payload.tokenBudget }

  if ($topK -lt 1) { $topK = 1 }
  if ($topK -gt 30) { $topK = 30 }
  if ($budget -lt 128) { $budget = 128 }
  if ($budget -gt 16000) { $budget = 16000 }

  $queryTokens = Invoke-LlamaTokenize -Content $query -Model $model -WithPieces $false
  $queryTokenCount = @($queryTokens.tokens).Count
  $terms = @(Get-RagTerms $query)

  $queryLower = $query.ToLowerInvariant().Trim()

  # Detect exact references to any indexed filename.  This is a strong
  # file-level signal before individual chunks are ranked.
  $exactFiles = @()
  foreach ($f in @(Get-RagIndexedFiles)) {
    $fullName = [string]$f.name
    if (-not $fullName) { continue }
    $leaf = [System.IO.Path]::GetFileName($fullName)

    if ($query.IndexOf($fullName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ($leaf -and $query.IndexOf($leaf, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
      $exactFiles += $fullName
    }
  }
  $exactFiles = @($exactFiles | Select-Object -Unique)

  # Lightweight code-aware intent signals.  These are ranking hints, not parsers.
  $signals = @()
  if ($queryLower -match '\bimports?\b') {
    $signals += [pscustomobject]@{ name='imports'; patterns=@('import '); boost=38.0 }
  }
  if ($queryLower -match '\bpackages?\b') {
    $signals += [pscustomobject]@{ name='package'; patterns=@('package '); boost=30.0 }
  }
  if ($queryLower -match '\bexceptions?\b|\berror handling\b|\bthrows?\b|\bcatch\b') {
    $signals += [pscustomobject]@{ name='exceptions'; patterns=@('catch ','throws ','exception'); boost=24.0 }
  }
  if ($queryLower -match '\bmethods?\b|\bfunctions?\b|\bprocedures?\b') {
    $signals += [pscustomobject]@{ name='methods/functions'; patterns=@('public ','private ','protected ','function ','procedure '); boost=14.0 }
  }
  if ($queryLower -match '\bsql\b|\bquery\b|\bselect\b|\binsert\b|\bupdate\b|\bdelete\b') {
    $signals += [pscustomobject]@{ name='sql'; patterns=@('select ','insert ','update ','delete ',' from ',' where '); boost=22.0 }
  }
  if ($queryLower -match '\bparameters?\b|\barguments?\b') {
    $signals += [pscustomobject]@{ name='parameters'; patterns=@('parameter','getparameter','param','argument'); boost=18.0 }
  }
  if ($queryLower -match '\bconnection\b|\bjdbc\b|\bdatabase\b') {
    $signals += [pscustomobject]@{ name='database/jdbc'; patterns=@('connection','jdbc','preparedstatement','resultset','datasource'); boost=22.0 }
  }
  if ($queryLower -match '\bclass\b|\binterface\b|\benum\b') {
    $signals += [pscustomobject]@{ name='type declaration'; patterns=@('class ','interface ','enum '); boost=16.0 }
  }

  $scored = New-Object System.Collections.Generic.List[object]

  foreach ($c in @($script:RagIndex)) {
    $textLower = ([string]$c.text).ToLowerInvariant()
    $file = [string]$c.file
    $fileLower = $file.ToLowerInvariant()
    $leafLower = ([System.IO.Path]::GetFileName($file)).ToLowerInvariant()
    $score = 0.0
    $matched = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($exactFiles.Count -gt 0) {
      if ($exactFiles -contains $file) {
        $score += 100.0
        $reasons.Add("exact filename match")
      }
      else {
        $score -= 25.0
      }
    }

    if ($leafLower -and $queryLower.Contains($leafLower)) {
      $score += 45.0
      $reasons.Add("filename mentioned")
    }

    foreach ($term in $terms) {
      $termEsc = [regex]::Escape($term)
      $occ = ([regex]::Matches($textLower, $termEsc)).Count
      $fileOcc = ([regex]::Matches($fileLower, $termEsc)).Count

      if ($occ -gt 0 -or $fileOcc -gt 0) {
        $matched.Add($term)
        $identifierBonus = if ($term.Contains("_") -or $term.Contains(".") -or $term.Contains("$")) { 8.0 } else { 2.0 }
        $score += ($occ * 1.5) + ($fileOcc * 8.0) + $identifierBonus
        if ($reasons.Count -lt 10) { $reasons.Add("term:$term") }
      }
    }

    if ($queryLower.Length -ge 8 -and $textLower.Contains($queryLower)) {
      $score += 30.0
      $reasons.Add("exact query phrase")
    }

    foreach ($sig in $signals) {
      $hits = 0
      foreach ($pattern in @($sig.patterns)) {
        if ($textLower.Contains(([string]$pattern).ToLowerInvariant())) { $hits++ }
      }
      if ($hits -gt 0) {
        $score += ([double]$sig.boost + [Math]::Min(12.0, ($hits - 1) * 3.0))
        if ($reasons.Count -lt 10) { $reasons.Add("code-signal:$($sig.name)") }
      }
    }

    if ($score -gt 0) {
      $scored.Add([pscustomobject]@{
        chunk = $c
        score = [Math]::Round($score, 3)
        matchedTerms = $matched.ToArray()
        reasons = $reasons.ToArray()
      })
    }
  }

  $ordered = @($scored | Sort-Object @{Expression="score";Descending=$true},
                                      @{Expression={$_.chunk.file};Descending=$false},
                                      @{Expression={$_.chunk.startLine};Descending=$false})

  $picked = New-Object System.Collections.Generic.List[object]
  $used = 0

  foreach ($s in $ordered) {
    if ($picked.Count -ge $topK) { break }
    $count = [int]$s.chunk.tokenCount

    if ($picked.Count -gt 0 -and ($used + $count) -gt $budget) { continue }

    $picked.Add([pscustomobject]@{
      id = $s.chunk.id
      file = $s.chunk.file
      startLine = $s.chunk.startLine
      endLine = $s.chunk.endLine
      tokenCount = $count
      score = $s.score
      matchedTerms = $s.matchedTerms
      reasons = $s.reasons
      text = $s.chunk.text
    })
    $used += $count

    if ($used -ge $budget) { break }
  }

  return @{
    ok = $true
    retrievalMethod = "token-aware lexical code retrieval with exact-file and code-intent ranking"
    queryTokenCount = $queryTokenCount
    queryTerms = $terms
    tokenBudget = $budget
    tokensSelected = $used
    count = $picked.Count
    chunks = $picked.ToArray()
    indexMeta = $script:RagMeta
    diagnostics = @{
      exactFileMatches = @($exactFiles)
      codeSignals = @($signals | ForEach-Object { $_.name })
      candidateCount = [int]$ordered.Count
    }
  }
}

function Get-RagIndexedFiles {
  $byFile = @{}

  foreach ($c in @($script:RagIndex)) {
    $name = [string]$c.file
    if (-not $name) { continue }

    if (-not $byFile.ContainsKey($name)) {
      $byFile[$name] = @{
        name = $name
        chunkCount = 0
        indexedTokens = 0
      }
    }

    $byFile[$name].chunkCount = [int]$byFile[$name].chunkCount + 1
    $byFile[$name].indexedTokens = [int]$byFile[$name].indexedTokens + [int]$c.tokenCount
  }

  $files = @()
  foreach ($name in @($byFile.Keys | Sort-Object)) {
    $x = $byFile[$name]
    $files += [pscustomobject]@{
      name = [string]$x.name
      chunkCount = [int]$x.chunkCount
      indexedTokens = [int]$x.indexedTokens
    }
  }

  return $files
}

function Get-RagStatus {
  $files = @(Get-RagIndexedFiles)

  return @{
    ok = $true
    meta = $script:RagMeta
    active = ($script:RagIndex.Count -gt 0)
    persistencePath = $RagStorePath
    indexedFiles = @($files)
    indexedFileNames = @($files | ForEach-Object { $_.name })
  }
}

Load-RagIndex

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
Write-Host "RAG Store : $RagStorePath"
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
          message = "Open the TGAIC HTML directly; use /health, /v1/*, /models*, /rag/*, or /hf/models for API access."
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


      if ($path -eq "/rag/status" -and $req.HttpMethod -eq "GET") {
        Write-Json $res (Get-RagStatus)
        continue
      }

      if ($path -eq "/rag/index" -and $req.HttpMethod -eq "POST") {
        try {
          $payload = Read-JsonBody $req
          $result = Build-RagIndex $payload
          Write-Json $res $result
        }
        catch {
          Write-Json $res @{
            ok = $false
            error = $_.Exception.Message
            message = "RAG index build failed. Confirm a model is loaded in llama-server so /tokenize is available."
          } 400
        }
        continue
      }

      if ($path -eq "/rag/search" -and $req.HttpMethod -eq "POST") {
        try {
          $payload = Read-JsonBody $req 1048576
          $result = Search-RagIndex $payload
          Write-Json $res $result
        }
        catch {
          Write-Json $res @{
            ok = $false
            error = $_.Exception.Message
            message = "RAG retrieval failed."
          } 400
        }
        continue
      }

      if ($path -eq "/rag/clear" -and $req.HttpMethod -eq "POST") {
        $meta = Clear-RagIndex
        Write-Json $res @{
          ok = $true
          meta = $meta
          message = "RAG index cleared."
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
        Write-Json $res @{ error = "Use /health, /v1/*, /models*, /rag/*, or /hf/models" } 404
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
