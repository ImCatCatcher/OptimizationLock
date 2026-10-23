# gameinfo_updater.ps1 - auto-update Deadlock's gameinfo.gi from OptimizationLock
#
# PowerShell port of the python script. Grabs a config variant from the repo,
# re-applies your locked convars from an overrides file, backs up the old file
# and writes the result.
#
# usage: just run it -- an interactive menu opens

$ErrorActionPreference = "Stop"
$VERSION = "2.0.0"
$REPO = "Sqooky/OptimizationLock"
$RAW_BASE = "https://raw.githubusercontent.com/{0}/{1}/{2}"
$DEFAULT_REF = "main"
$SCRIPT_REPO_PATH = "auto updater/gameinfo_updater.ps1"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$CFG_PATH = Join-Path $SCRIPT_DIR "updater_config.json"

# name -> @{ desc = ...; path = path in repo }
$CONFIGS = [ordered]@{
    "sqooky"      = @{ desc = "Sqooky's OptimizationLock (recommended)";       path = "Sqooky's .gi/gameinfo.gi" }
    "performance" = @{ desc = "Sqooky's Max FPS config (best performance)";    path = "maximumfps or minimum spec config and resources here/gameinfo.gi" }
    "boot"        = @{ desc = "Boot's Maximum FPS";                            path = "boot's maxium fps config/gameinfo.gi" }
    "kaiz"        = @{ desc = "Kaizuchaneru's Minimum Spec";                   path = "kaizuchanerus minimum spec/gameinfo.gi" }
    "piggy"       = @{ desc = "Piggy's Config";                                path = "Piggy's config/gameinfo.gi" }
    "eskay"       = @{ desc = "Eskay's modified fork of Sqooky's";             path = "Eskay's config/gameinfo.gi" }
    "clean"       = @{ desc = "Clean / Near-Vanilla";                          path = "clean gameinfo.gi/gameinfo.gi" }
}

$MANAGED_TAG = "// ===== gameinfo-updater added convars"
$MANAGED_HEADER = "        $MANAGED_TAG -- do not edit this block manually ====="
$MANAGED_FOOTER = "        // ===== end gameinfo-updater added convars ====="
$CONVAR_INDENT = "        "
$CONVAR_RE = '^(?<indent>[ \t]*)(?<slashes>//[ \t]*)?(?<name>\w+)(?<pad>[ \t]+)(?<value>"[^"\r\n]*"|\S+)(?<trail>[ \t]+//[^\r\n]*)?[ \t]*$'

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
$script:UseColor = -not [Console]::IsOutputRedirected

function c([string]$code, [string]$s) {
    if ($script:UseColor) { "$([char]27)[$code m$s$([char]27)[0m" } else { $s }
}
function bold([string]$s)   { c "1" $s }
function dim([string]$s)    { c "2" $s }
function green([string]$s)  { c "32" $s }
function yellow([string]$s) { c "33" $s }
function red([string]$s)    { c "31" $s }
function cyan([string]$s)   { c "36" $s }
function tag-ok    { green "[+]" }
function tag-warn  { yellow "[!]" }
function tag-err   { red "[x]" }
function rule      { dim ("=" * 72) }

function print-banner {
    Write-Host ""
    Write-Host ("  " + (bold (cyan "gameinfo-updater")) + (dim "  v$VERSION  --  Deadlock gameinfo.gi auto-updater"))
    Write-Host ("  " + (dim "https://github.com/$REPO"))
    Write-Host ("  " + (rule))
}

function print-header([string]$title) {
    Write-Host ""
    Write-Host ("  " + (bold $title))
    Write-Host ("  " + (rule))
}

function clear-screen { Clear-Host }

function fatal([string]$msg) {
    Write-Host $msg
    exit 1
}

# ---------------------------------------------------------------------------
# config file (shared with the python version)
# ---------------------------------------------------------------------------
function load-config-json {
    try {
        return Get-Content $CFG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function save-config-json($obj) {
    try {
        # UTF8 without BOM -- the python version cannot read a BOM'd json
        $json = $obj | ConvertTo-Json
        [IO.File]::WriteAllText($CFG_PATH, $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-Host ("  {0}  Could not write {1}: {2}" -f (tag-warn), (Split-Path -Leaf $CFG_PATH), $_.Exception.Message)
    }
}

function load-saved-config {
    $cfg = load-config-json
    if ($null -ne $cfg -and $cfg.PSObject.Properties["config"]) { return [string]$cfg.config }
    return $null
}

function load-last-check {
    $cfg = load-config-json
    if ($null -ne $cfg -and $cfg.PSObject.Properties["last_self_update_check"]) {
        try { return [datetime]$cfg.last_self_update_check } catch { return $null }
    }
    return $null
}

function save-last-check([datetime]$when) {
    $data = @{}
    $cfg = load-config-json
    if ($null -ne $cfg) {
        $cfg.PSObject.Properties | ForEach-Object { $data[$_.Name] = $_.Value }
    }
    $data["last_self_update_check"] = $when.ToString("yyyy-MM-ddTHH:mm:ss")
    save-config-json ([pscustomobject]$data)
}

# ---------------------------------------------------------------------------
# networking
# ---------------------------------------------------------------------------
function fetch-text-simple([string]$url) {
    # returns the body as a string; throws on error (caller decides)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($url)
    $request.UserAgent = "gameinfo-updater"
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally {
        $response.Close()
    }
}

# ---------------------------------------------------------------------------
# config sources
# ---------------------------------------------------------------------------
function config-to-url([string]$name) {
    $path = $CONFIGS[$name].path -replace " ", "%20" -replace "'", "%27"
    return $RAW_BASE -f $REPO, $DEFAULT_REF, $path
}

function normalize-github-url([string]$url) {
    if ($url -match "raw\.githubusercontent\.com") { return $url }
    if ($url -match "^https://github\.com/([^/]+/[^/]+)/blob/([^/]+)/(.+)$") {
        return "https://raw.githubusercontent.com/{0}/{1}/{2}" -f $Matches[1], $Matches[2], $Matches[3]
    }
    return $url
}

# ---------------------------------------------------------------------------
# gameinfo parsing / overrides
# ---------------------------------------------------------------------------
function split-keepends([string]$text) {
    # like python's splitlines(keepends=True)
    $parts = [regex]::Split($text, "(?<=\r?\n)")
    if ($parts.Length -gt 0 -and $parts[$parts.Length - 1] -eq "") {
        return $parts[0..($parts.Length - 2)]
    }
    return $parts
}

function find-convars-block($lines) {
    # returns @($openLine, $closeLine) as 0-based indices, or @(-1, -1)
    # openLine is the line holding the '{' -- it may not be the 'ConVars' line
    $text = -join $lines
    $m = [regex]::Match($text, "\bConVars\b\s*\{")
    if (-not $m.Success) { return , @(-1, -1) }

    $braceIdx = $m.Index + $m.Value.Length - 1
    $openLine = ($text.Substring(0, $braceIdx).ToCharArray() | Where-Object { $_ -eq "`n" }).Count

    $depth = 0
    for ($i = $openLine; $i -lt $lines.Count; $i++) {
        $noComment = [regex]::Replace($lines[$i], "//[^\r\n]*", "")
        $depth += ([regex]::Matches($noComment, "\{")).Count - ([regex]::Matches($noComment, "\}")).Count
        if ($depth -eq 0) { return , @($openLine, $i) }
    }
    return , @(-1, -1)
}

function strip-managed-block([string]$text) {
    $pattern = "[ \t]*" + [regex]::Escape($MANAGED_TAG) + ".*?" + [regex]::Escape($MANAGED_FOOTER) + "[^\r\n]*\r?\n?"
    return [regex]::Replace($text, $pattern, "", [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function parse-overrides([string]$path) {
    # returns @{ set = @{name=value}; comment = [list of names] }
    $setMap = @{}
    $commentSet = New-Object System.Collections.Generic.List[string]

    foreach ($raw in [IO.File]::ReadAllLines($path)) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }

        if ($line -match "^//\s*(\w+)(?:\s+#.*)?$") {
            $commentSet.Add($Matches[1])
            continue
        }
        if ($line -match "^(\w+)\s+(.+)$") {
            $value = [regex]::Replace($Matches[2], "\s+#.*$", "").Trim()
            $setMap[$Matches[1]] = $value
            continue
        }
        Write-Host ("  [overrides] Warning: unrecognized line -- {0}" -f $raw)
    }
    return @{ set = $setMap; comment = $commentSet }
}

function quote-val([string]$v) {
    if ($v.StartsWith('"') -and $v.EndsWith('"')) { return $v }
    return '"' + $v + '"'
}

function process-body($body, $setMap, $commentSet) {
    # returns @{ lines = newBody; summary = ... }
    $newLines = New-Object System.Collections.Generic.List[string]
    $subDepth = 0
    $handledSet = @{}
    $handledComment = @{}
    $setChanges = New-Object System.Collections.Generic.List[object]
    $commentChanges = New-Object System.Collections.Generic.List[object]
    $commentValues = @{}
    $commentTrails = @{}

    foreach ($line in $body) {
        $noComment = [regex]::Replace($line, "//[^\r\n]*", "")
        $opens = ([regex]::Matches($noComment, "\{")).Count
        $closes = ([regex]::Matches($noComment, "\}")).Count

        if ($subDepth -gt 0 -or $opens -gt $closes) {
            $subDepth += $opens - $closes
            $newLines.Add($line)
            continue
        }

        $m = [regex]::Match($line.TrimEnd("`r", "`n"), $CONVAR_RE)
        if (-not $m.Success) { $newLines.Add($line); continue }

        $name = $m.Groups["name"].Value
        $isComment = $m.Groups["slashes"].Success
        $oldVal = $m.Groups["value"].Value
        $indent = $m.Groups["indent"].Value
        $pad = $m.Groups["pad"].Value
        $trail = $m.Groups["trail"].Value

        if ($setMap.ContainsKey($name)) {
            $newVal = quote-val $setMap[$name]
            $newLines.Add("$indent$name$pad$newVal$trail$([Environment]::NewLine)")
            if (-not $handledSet.ContainsKey($name) -and ($isComment -or $oldVal -ne $newVal)) {
                $displayOld = if ($isComment) { "//$oldVal" } else { $oldVal }
                $setChanges.Add([pscustomobject]@{ name = $name; old = $displayOld; new = $newVal; trail = $trail })
            }
            $handledSet[$name] = $true
        }
        elseif ($commentSet -contains $name) {
            if (-not $isComment) {
                $newLines.Add("$indent// $name$pad$oldVal$trail$([Environment]::NewLine)")
                if (-not $handledComment.ContainsKey($name)) {
                    $commentChanges.Add([pscustomobject]@{ name = $name; val = $oldVal; trail = $trail })
                }
            } else {
                $newLines.Add($line)
            }
            $handledComment[$name] = $true
            $commentValues[$name] = $oldVal
            $commentTrails[$name] = $trail
        }
        else {
            $newLines.Add($line)
        }
    }

    return @{
        lines = $newLines
        summary = @{
            set = $setChanges; commented = $commentChanges
            commentValues = $commentValues; commentTrails = $commentTrails
            handledSet = $handledSet; handledComment = $handledComment
        }
    }
}

function apply-overrides([string]$text, $setMap, $commentSet) {
    $text = strip-managed-block $text
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]](split-keepends $text)

    $idx = find-convars-block $lines
    $openLine = $idx[0]; $closeLine = $idx[1]
    if ($openLine -lt 0) { fatal "  $(tag-err)  Could not locate ConVars block in the gameinfo file" }

    $body = $lines.GetRange($openLine + 1, $closeLine - $openLine - 1)
    $result = process-body $body $setMap $commentSet
    $newBody = $result.lines
    $summary = $result.summary

    $unmatched = @($setMap.Keys | Where-Object { -not $summary.handledSet.ContainsKey($_) })
    if ($unmatched.Count -gt 0) {
        $inj = New-Object System.Collections.Generic.List[string]
        $inj.Add("$MANAGED_HEADER$eol")
        foreach ($name in $unmatched) { $inj.Add("$CONVAR_INDENT$name $(quote-val $setMap[$name])$eol") }
        $inj.Add("$MANAGED_FOOTER$eol")
        $newBody.InsertRange(0, [System.Collections.Generic.List[string]]$inj)
    }
    $summary["injected"] = $unmatched

    $pre = $lines.GetRange(0, $openLine + 1)
    $post = $lines.GetRange($closeLine, $lines.Count - $closeLine)
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange($pre); $out.AddRange($newBody); $out.AddRange($post)
    return @{ text = (-join $out); summary = $summary }
}

function validate-braces([string]$text) {
    $stripped = [regex]::Replace($text, "//[^\r\n]*", "")
    $balance = ([regex]::Matches($stripped, "\{")).Count - ([regex]::Matches($stripped, "\}")).Count
    if ($balance -ne 0) {
        fatal ("  {0}  Brace balance of modified file is off by {1}. Refusing to write. Please report this as a bug" -f (tag-err), $balance)
    }
}

function extract-convars([string]$text) {
    # returns hashtable name -> @{ value = ...; commented = bool }
    $result = @{}
    $lines = [System.Collections.Generic.List[string]](split-keepends $text)
    $idx = find-convars-block $lines
    if ($idx[0] -lt 0) { return $result }
    $subDepth = 0
    for ($i = $idx[0] + 1; $i -lt $idx[1]; $i++) {
        $line = $lines[$i]
        $noComment = [regex]::Replace($line, "//[^\r\n]*", "")
        $opens = ([regex]::Matches($noComment, "\{")).Count
        $closes = ([regex]::Matches($noComment, "\}")).Count
        if ($subDepth -gt 0 -or $opens -gt $closes) { $subDepth += $opens - $closes; continue }
        $m = [regex]::Match($line.TrimEnd("`r", "`n"), $CONVAR_RE)
        if ($m.Success) {
            $result[$m.Groups["name"].Value] = @{ value = $m.Groups["value"].Value; commented = $m.Groups["slashes"].Success }
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# diff (small LCS-based unified diff, 3 lines of context)
# ---------------------------------------------------------------------------
function get-unified-diff($aLines, $bLines) {
    $n = $aLines.Count; $m = $bLines.Count
    # LCS table (trimmed to avoid huge memory on identical prefixes is skipped -- files are small)
    $lcs = New-Object "int[,]" ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            $i1 = $i + 1; $j1 = $j + 1
            if ($aLines[$i] -eq $bLines[$j]) { $lcs[$i, $j] = $lcs[$i1, $j1] + 1 }
            elseif ($lcs[$i1, $j] -ge $lcs[$i, $j1]) { $lcs[$i, $j] = $lcs[$i1, $j] }
            else { $lcs[$i, $j] = $lcs[$i, $j1] }
        }
    }
    $ops = New-Object System.Collections.Generic.List[object]  # @{ type = same/del/add; a = idx; b = idx }
    $i = 0; $j = 0
    while ($i -lt $n -and $j -lt $m) {
        if ($aLines[$i] -eq $bLines[$j]) { $ops.Add(@{ type = "same"; a = $i; b = $j }); $i++; $j++ }
        elseif ($lcs[$i + 1, $j] -ge $lcs[$i, $j + 1]) { $ops.Add(@{ type = "del"; a = $i; b = $j }); $i++ }
        else { $ops.Add(@{ type = "add"; a = $i; b = $j }); $j++ }
    }
    while ($i -lt $n) { $ops.Add(@{ type = "del"; a = $i; b = $j }); $i++ }
    while ($j -lt $m) { $ops.Add(@{ type = "add"; a = $i; b = $j }); $j++ }

    $out = New-Object System.Collections.Generic.List[string]
    $k = 0
    while ($k -lt $ops.Count) {
        if ($ops[$k].type -eq "same") { $k++; continue }
        $start = [Math]::Max(0, $k - 3)
        # extend hunk end past trailing context
        $end = $k
        $sameRun = 0
        while ($end -lt $ops.Count) {
            if ($ops[$end].type -eq "same") { $sameRun++ } else { $sameRun = 0 }
            if ($sameRun -gt 3) { break }
            $end++
        }
        $end = [Math]::Min($ops.Count, $end - [Math]::Max(0, $sameRun - 3))
        $hunk = $ops[$start..($end - 1)]
        $aStart = $hunk[0].a + 1
        $bStart = $hunk[0].b + 1
        $aCount = @($hunk | Where-Object { $_.type -ne "add" }).Count
        $bCount = @($hunk | Where-Object { $_.type -ne "del" }).Count
        $out.Add("@@ -$aStart,$aCount +$bStart,$bCount @@")
        foreach ($op in $hunk) {
            $txt = ""
            $prefix = " "
            if ($op.type -eq "del") { $prefix = "-"; $txt = $aLines[$op.a] }
            elseif ($op.type -eq "add") { $prefix = "+"; $txt = $bLines[$op.b] }
            else { $txt = $aLines[$op.a] }
            $txt = $txt -replace "`r`n$", "" -replace "`n$", ""
            $line = $prefix + $txt
            if ($op.type -eq "del") { $out.Add((red $line)) }
            elseif ($op.type -eq "add") { $out.Add((green $line)) }
            else { $out.Add($line) }
        }
        $k = $end
    }
    return $out
}

# ---------------------------------------------------------------------------
# summaries
# ---------------------------------------------------------------------------
function fmt-comment([string]$trail) {
    $s = $trail.Trim()
    if ($s.StartsWith("//")) { $s = $s.Substring(2) }
    return $s.Trim()
}

function print-summary($summary, $setMap, $commentSet) {
    print-header "Override Summary"

    if ($summary.set.Count -gt 0) {
        Write-Host ("  " + (cyan "SET (value-locked):"))
        foreach ($ch in $summary.set) {
            $line = "    {0}  {1}  ->  {2}" -f $ch.name, $ch.old, $ch.new
            $cmt = fmt-comment $ch.trail
            if ($cmt) { $line += "   // $cmt" }
            Write-Host $line
        }
    }
    if ($summary.injected.Count -gt 0) {
        Write-Host ("  " + (cyan "INJECTED (not found upstream; added to managed block):"))
        foreach ($name in $summary.injected) {
            Write-Host ("    {0}  {1}" -f $name, (quote-val $setMap[$name]))
        }
    }
    if ($summary.commented.Count -gt 0) {
        Write-Host ("  " + (cyan "COMMENTED OUT (upstream value shown):"))
        foreach ($ch in $summary.commented) {
            $line = "    {0}  {1}" -f $ch.name, $ch.val
            $cmt = fmt-comment $ch.trail
            if ($cmt) { $line += "   // $cmt" }
            Write-Host $line
        }
    }
    $alreadyOk = @($summary.handledComment.Keys | Where-Object { $summary.commented.name -notcontains $_ })
    if ($alreadyOk.Count -gt 0) {
        Write-Host ("  " + (cyan "ALREADY COMMENTED (no change needed):"))
        foreach ($name in $alreadyOk) {
            $line = "    {0}  {1}" -f $name, $summary.commentValues[$name]
            $cmt = fmt-comment $summary.commentTrails[$name]
            if ($cmt) { $line += "   // $cmt" }
            Write-Host $line
        }
    }
    $notFound = @($commentSet | Where-Object { -not $summary.handledComment.ContainsKey($_) })
    if ($notFound.Count -gt 0) {
        Write-Host ("  " + (yellow "NOT FOUND in upstream (comment directive had no effect):"))
        foreach ($name in $notFound) { Write-Host "    $name" }
    }
    if ($summary.set.Count -eq 0 -and $summary.injected.Count -eq 0 -and $summary.commented.Count -eq 0 -and $alreadyOk.Count -eq 0 -and $notFound.Count -eq 0) {
        Write-Host ("  " + (dim "No changes -- all overrides already match the upstream"))
    }
}

function print-upstream-changes($changes) {
    print-header ("Upstream ConVar Changes " + (dim "(ignoring overrides)"))
    if ($changes.added.Count -gt 0) {
        Write-Host ("  " + (cyan "ADDED in new version:"))
        foreach ($cv in $changes.added) { Write-Host ("    {0}{1}  {2}" -f $(if ($cv.commented) { "// " } else { "" }), $cv.name, $cv.value) }
    }
    if ($changes.removed.Count -gt 0) {
        Write-Host ("  " + (cyan "REMOVED in new version:"))
        foreach ($cv in $changes.removed) { Write-Host ("    {0}{1}  {2}" -f $(if ($cv.commented) { "// " } else { "" }), $cv.name, $cv.value) }
    }
    if ($changes.changed.Count -gt 0) {
        Write-Host ("  " + (cyan "CHANGED:"))
        foreach ($cv in $changes.changed) { Write-Host ("    {0}  {1}  ->  {2}" -f $cv.name, $cv.old, $cv.new) }
    }
    if ($changes.toggled.Count -gt 0) {
        Write-Host ("  " + (cyan "COMMENT STATE TOGGLED:"))
        foreach ($cv in $changes.toggled) {
            $oldS = if ($cv.oldCommented) { "commented" } else { "active" }
            $newS = if ($cv.newCommented) { "commented" } else { "active" }
            Write-Host ("    {0}  {1}  ({2} -> {3})" -f $cv.name, $cv.value, $oldS, $newS)
        }
    }
    if ($changes.added.Count -eq 0 -and $changes.removed.Count -eq 0 -and $changes.changed.Count -eq 0 -and $changes.toggled.Count -eq 0) {
        Write-Host ("  " + (dim "No upstream convar changes (ignoring overrides)"))
    }
}

function compare-convars($old, $new, $ignore) {
    $added = @(); $removed = @(); $changed = @(); $toggled = @()
    foreach ($name in $new.Keys) {
        if ($ignore -contains $name) { continue }
        if (-not $old.ContainsKey($name)) { $added += @{ name = $name; value = $new[$name].value; commented = $new[$name].commented }; continue }
        if ($old[$name].value -ne $new[$name].value) { $changed += @{ name = $name; old = $old[$name].value; new = $new[$name].value } }
        elseif ($old[$name].commented -ne $new[$name].commented) { $toggled += @{ name = $name; value = $new[$name].value; oldCommented = $old[$name].commented; newCommented = $new[$name].commented } }
    }
    foreach ($name in $old.Keys) {
        if (-not $ignore.Contains($name) -and -not $new.ContainsKey($name)) { $removed += @{ name = $name; value = $old[$name].value; commented = $old[$name].commented } }
    }
    return @{ added = $added; removed = $removed; changed = $changed; toggled = $toggled }
}

# ---------------------------------------------------------------------------
# backups / restore
# ---------------------------------------------------------------------------
function make-backup([string]$giPath) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $bak = Join-Path (Split-Path -Parent $giPath) "gameinfo.$stamp.bak"
    Copy-Item $giPath $bak
    Write-Host ("  {0}  Backup created: {1}" -f (tag-ok), $bak)
    return $bak
}

function find-latest-backup([string]$giPath) {
    $dir = Split-Path -Parent $giPath
    $candidates = @(Get-ChildItem $dir -Filter "gameinfo.????????_??????.bak" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

# ---------------------------------------------------------------------------
# gameinfo detection
# ---------------------------------------------------------------------------
function resolve-gi {
    if ($GameInfo) { return $GameInfo }
    $suffix = "steamapps/common/Deadlock/game/citadel/gameinfo.gi"
    $roots = @()
    if ($env:OS -eq "Windows_NT") {
        foreach ($envName in @("STEAM_PATH", "STEAMPATH")) {
            $val = [Environment]::GetEnvironmentVariable($envName)
            if ($val) { $roots = @($val) + $roots }
        }
        $roots += @("C:\Program Files (x86)\Steam", "C:\Program Files\Steam")
    } else {
        $roots += @(
            (Join-Path $HOME ".steam/steam"),
            (Join-Path $HOME ".local/share/Steam"),
            (Join-Path $HOME ".var/app/com.valvesoftware.Steam/.local/share/Steam")
        )
    }
    foreach ($root in $roots) {
        $p = Join-Path $root ($suffix -replace "/", [IO.Path]::DirectorySeparatorChar)
        if (Test-Path $p -PathType Leaf) { return $p }
    }
    fatal ("  {0}  Could not auto-detect gameinfo.gi`n       Use -GameInfo <path> to specify it" -f (tag-err))
}

# ---------------------------------------------------------------------------
# prompts / remembering config
# ---------------------------------------------------------------------------
function prompt-save-config([string]$name) {
    $answer = Read-Host ("  {0}  Remember config '{1}' as the default? [y/N]" -f (dim "(?)"), (bold $name))
    if ($answer -match "^(y|yes)$") {
        $data = @{}
        $cfg = load-config-json
        if ($null -ne $cfg) { $cfg.PSObject.Properties | ForEach-Object { $data[$_.Name] = $_.Value } }
        $data["config"] = $name
        save-config-json ([pscustomobject]$data)
        Write-Host ("  {0}  '{1}' is now the default config (stored in updater_config.json)" -f (tag-ok), (green (bold $name)))
    }
}

function ask-erase-saved-config([string]$name) {
    Write-Host ""
    Write-Host ("  {0}  {1} in updater_config.json is not a valid config name" -f (tag-err), (yellow $name))
    Write-Host "         Run 'list-configs' to see available names"
    $answer = Read-Host ("  Erase the saved config from updater_config.json? [y/N]")
    if ($answer -match "^(y|yes)$") {
        $data = @{}
        $cfg = load-config-json
        if ($null -ne $cfg) { $cfg.PSObject.Properties | ForEach-Object { if ($_.Name -ne "config") { $data[$_.Name] = $_.Value } } }
        save-config-json ([pscustomobject]$data)
        Write-Host ("  {0}  Erased. Pick a config with {1} (it can be remembered again)" -f (tag-ok), (bold "--config NAME"))
        exit 0
    }
    fatal ("  {0}  Saved config '{1}' is not valid -- nothing was erased`n       Overwrite it by running with -Config NAME" -f (tag-err), (yellow $name))
}

function load-upstream {
    if ($Url) {
        $rawUrl = normalize-github-url $Url
        Write-Host ("  {0}  Fetching {1}" -f (tag-ok), (dim $rawUrl))
        return @{ text = (fetch-text-simple $rawUrl); label = $rawUrl }
    }
    if ($Config) {
        if (-not $CONFIGS.Contains($Config)) {
            fatal ("  {0}  Unknown config '{1}'`n       Run 'list-configs' to see available names" -f (tag-err), (yellow $Config))
        }
        if ($Config -ne (load-saved-config)) { prompt-save-config $Config }
        $rawUrl = config-to-url $Config
        Write-Host ("  {0}  Fetching {1}" -f (tag-ok), (dim $rawUrl))
        return @{ text = (fetch-text-simple $rawUrl); label = $rawUrl }
    }
    $saved = load-saved-config
    if ($null -ne $saved) {
        if (-not $CONFIGS.Contains($saved)) { ask-erase-saved-config $saved }
        Write-Host ("  {0}  Config: {1}  (saved in updater_config.json)" -f (tag-ok), (green (bold $saved)))
        $rawUrl = config-to-url $saved
        Write-Host ("  {0}  Fetching {1}" -f (tag-ok), (dim $rawUrl))
        return @{ text = (fetch-text-simple $rawUrl); label = $rawUrl }
    }
    $rawUrl = config-to-url "sqooky"
    Write-Host ("  {0}  Fetching {1}" -f (tag-ok), (dim $rawUrl))
    return @{ text = (fetch-text-simple $rawUrl); label = $rawUrl }
}

function load-overrides {
    if ($Overrides) {
        if (-not (Test-Path $Overrides -PathType Leaf)) {
            fatal ("  {0}  -Overrides file not found: {1}" -f (tag-err), $Overrides)
        }
        $ovPath = $Overrides
    } else {
        $ovPath = Join-Path $SCRIPT_DIR "overrides.gi"
        if (-not (Test-Path $ovPath -PathType Leaf)) {
            Write-Host ("  {0}  No overrides.gi found -- proceeding without overrides" -f (dim "(i)"))
            return @{ set = @{}; comment = @() }
        }
    }
    $ov = parse-overrides $ovPath
    Write-Host ("  {0}  Overrides: {1}  ({2} value-lock(s), {3} comment-lock(s))" -f (tag-ok), $ovPath, $ov.set.Count, $ov.comment.Count)
    return $ov
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
function cmd-update {
    $upstream = load-upstream
    $upText = $upstream.text
    $sourceLabel = $upstream.label

    $ov = load-overrides
    $setMap = $ov.set
    $commentSet = $ov.comment

    foreach ($name in ($setMap.Keys | Where-Object { $commentSet -contains $_ } | Sort-Object)) {
        Write-Host ("  {0}  '{1}': value-locked AND comment-locked -- value-lock takes precedence" -f (tag-warn), $name)
    }

    $giPath = resolve-gi
    Write-Host ("  {0}  Target: {1}" -f (tag-ok), $giPath)

    if (Test-Path $giPath -PathType Leaf) {
        try {
            $currentText = [IO.File]::ReadAllText($giPath)
            $ignore = @($setMap.Keys) + @($commentSet)
            $changes = compare-convars (extract-convars $currentText) (extract-convars $upText) $ignore
            print-upstream-changes $changes
        } catch {
            Write-Host ("  {0}  Upstream changes could not be computed: {1}" -f (dim "(i)"), $_.Exception.Message)
        }
    }

    $emptySummary = @{
        set = @(); commented = @(); injected = @()
        commentValues = @{}; commentTrails = @{}
        handledSet = @{}; handledComment = @{}
    }
    if ($setMap.Count -gt 0 -or $commentSet.Count -gt 0) {
        $applied = apply-overrides $upText $setMap $commentSet
        $modified = $applied.text
        $summary = $applied.summary
    } else {
        $modified = $upText
        $summary = $emptySummary
    }

    validate-braces $modified

    if ($Diff) {
        $original = if (Test-Path $giPath -PathType Leaf) { [IO.File]::ReadAllText($giPath) } else { "" }
        print-header "Unified Diff (current file -> new)"
        $d = get-unified-diff (split-keepends $original) (split-keepends $modified)
        if ($d.Count -eq 0) { Write-Host ("  " + (dim "(no diff -- file unchanged)")) } else { $d | ForEach-Object { Write-Host $_ } }
    }

    if ($DryRun) {
        print-summary $summary $setMap $commentSet
        Write-Host ""
        Write-Host ("  {0}  DRY RUN -- nothing was written" -f (yellow (bold "[dry run]")))
        return
    }

    $existed = Test-Path $giPath -PathType Leaf
    $preBytes = if ($existed) { [IO.File]::ReadAllBytes($giPath) } else { $null }

    $dir = Split-Path -Parent $giPath
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $tmpPath = "$giPath.tmp"
    try {
        [IO.File]::WriteAllText($tmpPath, $modified, (New-Object Text.UTF8Encoding($false)))
        Move-Item $tmpPath $giPath -Force
    } catch {
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue }
        Write-Host ("  {0}  Could not write to {1} -- it is likely locked by the game.`n       Close Deadlock and try again from the menu" -f (tag-err), $giPath)
        throw "locked"
    }

    if (-not $NoBackup -and $null -ne $preBytes) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $bak = Join-Path $dir "gameinfo.$stamp.bak"
        [IO.File]::WriteAllBytes($bak, $preBytes)
        Write-Host ("  {0}  Backup created: {1}" -f (tag-ok), $bak)
    }

    Write-Host ("  {0}  Written: {1}" -f (green (bold "[ok]")), $giPath)
    print-summary $summary $setMap $commentSet
}

function cmd-list-configs {
    print-header "Available Configs"
    Write-Host ("  Use with " + (bold "-Config <name>") + "`n")
    $width = ($CONFIGS.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum + 2
    foreach ($name in $CONFIGS.Keys) {
        Write-Host ("  " + (green (bold $name.PadRight($width))) + $CONFIGS[$name].desc)
        Write-Host ("  " + (dim ((" " * $width) + (config-to-url $name))))
        Write-Host ""
    }
}

function cmd-restore {
    $giPath = resolve-gi
    if ($Latest) {
        $bak = find-latest-backup $giPath
        if ($null -eq $bak) { fatal ("  {0}  No backups found in {1}" -f (tag-err), (Split-Path -Parent $giPath)) }
    } else {
        if (-not (Test-Path $BackupFile -PathType Leaf)) { fatal ("  {0}  Backup file not found: {1}" -f (tag-err), $BackupFile) }
        $bak = $BackupFile
    }
    if (Test-Path $giPath -PathType Leaf) { make-backup $giPath | Out-Null }
    Copy-Item $bak $giPath -Force
    Write-Host ("  {0}  Restored: {1}`n       {2}  {3}" -f (tag-ok), $bak, (dim "->"), $giPath)
}

function cmd-backup {
    $giPath = resolve-gi
    if (-not (Test-Path $giPath -PathType Leaf)) { fatal ("  {0}  gameinfo.gi not found: {1}" -f (tag-err), $giPath) }
    make-backup $giPath | Out-Null
}

# ---------------------------------------------------------------------------
# self-update
# ---------------------------------------------------------------------------
function version-tuple([string]$s) {
    $parts = @()
    foreach ($chunk in $s.Trim().TrimStart("vV").Split(".")) {
        $m = [regex]::Match($chunk, "\d+")
        $parts += [int]$(if ($m.Success) { $m.Value } else { 0 })
    }
    return ,$parts
}

function check-self-update([bool]$force) {
    if ($NoSelfUpdate) { return }
    if ($env:GAMEINFO_UPDATER_NO_SELF_UPDATE) { return }

    $last = load-last-check
    if (-not $force -and $null -ne $last -and ((Get-Date) - $last).TotalDays -le 15) { return }

    $age = if ($null -eq $last) { "never checked" } else { "last checked {0}" -f $last.ToString("yyyy-MM-dd") }
    if (-not $force) {
        $answer = Read-Host ("  {0}  {1} -- check for a new script version now? [y/N]" -f (tag-warn), $age)
        if ($answer -notmatch "^(y|yes)$") {
            save-last-check (Get-Date)
            return
        }
    }

    $pathEsc = $SCRIPT_REPO_PATH -replace " ", "%20" -replace "'", "%27"
    $url = $RAW_BASE -f $REPO, $DEFAULT_REF, $pathEsc
    try {
        $remoteText = fetch-text-simple $url
    } catch {
        # do not save the last-check date: the check did not happen,
        # so the user is asked again on the next run
        Write-Host ("  {0}  Could not check for script updates (offline?)" -f (dim "(i)"))
        return
    }
    save-last-check (Get-Date)

    $m = [regex]::Match($remoteText, '(?m)^\$VERSION\s*=\s*"([^"]+)"')
    if (-not $m.Success) {
        Write-Host ("  {0}  Could not parse the version of the remote script" -f (tag-warn))
        return
    }
    $remoteVersion = $m.Groups[1].Value

    $local = version-tuple $VERSION
    $remote = version-tuple $remoteVersion
    $isNewer = $false
    for ($i = 0; $i -lt [Math]::Max($local.Count, $remote.Count); $i++) {
        $lv = if ($i -lt $local.Count) { $local[$i] } else { 0 }
        $rv = if ($i -lt $remote.Count) { $remote[$i] } else { 0 }
        if ($rv -gt $lv) { $isNewer = $true; break }
        if ($rv -lt $lv) { break }
    }
    if (-not $isNewer) {
        Write-Host ("  {0}  Script is up to date (v{1})" -f (tag-ok), $VERSION)
        return
    }

    Write-Host ""
    Write-Host ("  {0}  New script version available: {1} -> {2}" -f (tag-warn), (dim $VERSION), (green (bold $remoteVersion)))
    $answer = Read-Host ("  Install it now? [y/N]")
    if ($answer -notmatch "^(y|yes)$") { return }

    $scriptPath = $PSCommandPath
    $backup = "$scriptPath.$VERSION.bak"
    try {
        Copy-Item $scriptPath $backup -Force
        $tmpPath = "$scriptPath.tmp"
        [IO.File]::WriteAllText($tmpPath, $remoteText, (New-Object Text.UTF8Encoding($false)))
        Move-Item $tmpPath $scriptPath -Force
    } catch {
        fatal ("  {0}  Could not update the script -- {1}`n  Re-download it from {2}" -f (tag-err), $_.Exception.Message, $url)
    }
    Write-Host ("  {0}  Script updated: {1}  (backup: {2})`n  Please re-run your command" -f (tag-ok), $scriptPath, (dim $backup))
    exit 0
}

# ---------------------------------------------------------------------------
# interactive menu
# ---------------------------------------------------------------------------
function ask-choice([string]$prompt, [int]$choices) {
    # returns 1..N, or 0 for quit
    while ($true) {
        $raw = Read-Host ("  {0}  {1} [1-{2}/q]" -f (cyan ">"), $prompt, $choices)
        if ($raw -match "^(q|quit|exit)$") { return 0 }
        if ($raw -match "^\d+$" -and [int]$raw -ge 1 -and [int]$raw -le $choices) { return [int]$raw }
        Write-Host ("  {0}  Invalid choice: '{1}'" -f (tag-warn), $raw)
    }
}

function menu-pick-config {
    $names = @($CONFIGS.Keys)
    $saved = load-saved-config
    clear-screen
    print-banner
    print-header "Pick a Config"
    for ($i = 0; $i -lt $names.Count; $i++) {
        $marker = if ($names[$i] -eq $saved) { green " <- saved" } else { "" }
        Write-Host ("  {0}  {1}{2}" -f (bold ($i + 1)), (green (bold $names[$i].PadRight(13))), ($CONFIGS[$names[$i]].desc + $marker))
    }
    $idx = ask-choice "Config number:" $names.Count
    if ($idx -eq 0) { return $null }
    return $names[$idx - 1]
}

function menu-update([string]$configName) {
    if ($null -eq $configName -or "" -eq $configName) {
        $configName = menu-pick-config
        if ($null -eq $configName) { return }
    }
    $script:Config = $configName
    $script:Url = $null
    cmd-update
}

function pause-back-to-menu {
    $null = Read-Host ("`n  Press Enter to return to the menu...")
}

function interactive-menu {
    $firstPage = $true
    while ($true) {
        if ($firstPage) { $firstPage = $false }
        else {
            pause-back-to-menu
            clear-screen
            print-banner
        }

        $saved = load-saved-config
        $cfgLast = load-last-check
        $overdue = ($null -eq $cfgLast) -or (((Get-Date) - $cfgLast).TotalDays -gt 15)

        print-header "Main Menu"
        $configHint = if ($saved -and $CONFIGS.Contains($saved)) { dim "  (config: $saved)" } else { dim "  (config: sqooky, default)" }
        Write-Host ("  {0}  Update gameinfo.gi now{1}" -f (bold "1"), $configHint)
        Write-Host ("  {0}  Pick a config and update" -f (bold "2"))
        Write-Host ("  {0}  Backup current gameinfo.gi" -f (bold "3"))
        Write-Host ("  {0}  Restore the latest backup" -f (bold "4"))
        $updateHint = ""
        if ($overdue) {
            $age = if ($null -eq $cfgLast) { "never" } else { $cfgLast.ToString("yyyy-MM-dd") }
            $updateHint = yellow "  <-- update check overdue (last: $age)"
        }
        Write-Host ("  {0}  Check for a new script version{1}" -f (bold "5"), $updateHint)
        Write-Host ("  {0}  Quit" -f (bold "q"))

        $choice = ask-choice "Action:" 5
        if ($choice -eq 0) { Write-Host "  Bye"; return }
        switch ($choice) {
            1 { try { menu-update $(if ($saved -and $CONFIGS.Contains($saved)) { $saved } else { $null }) } catch { if ($_.Exception.Message -ne "locked") { Write-Host $_.Exception.Message } } }
            2 { try { menu-update $null } catch { if ($_.Exception.Message -ne "locked") { Write-Host $_.Exception.Message } } }
            3 { try { cmd-backup } catch { if ($_.Exception.Message -ne "locked") { Write-Host $_.Exception.Message } } }
            4 { try { $script:Latest = $true; cmd-restore } catch { if ($_.Exception.Message -ne "locked") { Write-Host $_.Exception.Message } } }
            5 { check-self-update $true }
        }
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$Url = $null
$Config = $null
$Overrides = $null
$GameInfo = $null
$DryRun = $false
$Diff = $false
$NoBackup = $false
$NoSelfUpdate = $false
$Latest = $false
$BackupFile = $null

clear-screen
print-banner
interactive-menu
