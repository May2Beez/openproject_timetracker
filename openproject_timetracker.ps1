#Requires -Version 5.1
<#
.SYNOPSIS
    OpenProject Time Tracker - Console App

.DESCRIPTION
    Scans your time entries, lists unfilled days, and lets you log hours.
    Supports favorite work packages (stored in ~/.openproject_favorites.json).
    Activity is hardcoded to ID=1 / "Management".

    OPENPROJECT_URL and OPENPROJECT_TOKEN are read from the environment or from
    the nearest .env file (searched upwards from the script directory).

.EXAMPLE
    .\openproject_timetracker.ps1
#>

$ErrorActionPreference = 'Stop'


# ── Hardcoded activity ────────────────────────────────────────────────────────

$ACTIVITY_ID   = 1
$ACTIVITY_NAME = 'Management'


# ── Small helpers ─────────────────────────────────────────────────────────────

function Read-Input([string]$Prompt) {
    Write-Host $Prompt -NoNewline
    $line = Read-Host
    if ($null -eq $line) {
        throw 'No more input.'
    }
    return $line.Trim()
}


function Select-FirstValue {
    # First truthy argument (falls back to the last one), like chaining Python's `or`.
    foreach ($value in $args) {
        if ($value) { return $value }
    }
    return $args[-1]
}


function ConvertTo-MenuIndex([string]$Raw, [int]$Count) {
    # 1-based menu choice -> 0-based index, or -1 when the choice is invalid.
    if ($Raw -match '^[0-9]{1,9}$') {
        $n = [int]$Raw
        if ($n -ge 1 -and $n -le $Count) { return $n - 1 }
    }
    return -1
}


function Format-IsoDate([datetime]$Date) {
    return $Date.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}


function ConvertFrom-IsoDate([string]$Text) {
    return [datetime]::ParseExact($Text, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}


function Format-DisplayDate([datetime]$Date) {
    return $Date.ToString('dd-MMM-yyyy', [cultureinfo]::InvariantCulture)
}


# ── Favorites storage ─────────────────────────────────────────────────────────

$FAVORITES_FILE = Join-Path $HOME '.openproject_favorites.json'


function Get-Favorite {
    if (-not (Test-Path -LiteralPath $FAVORITES_FILE)) {
        return
    }
    try {
        $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($FAVORITES_FILE))
        foreach ($f in $parsed) { $f }
    } catch {
        return
    }
}


function Save-Favorite($Favorites) {
    $json = ConvertTo-Json -InputObject @($Favorites) -Depth 5
    [IO.File]::WriteAllText($FAVORITES_FILE, $json)
}


function Add-Favorite($WorkPackage) {
    # Add WP to favorites. Returns $false if already present.
    $favorites = @(Get-Favorite)
    if ($favorites | Where-Object { $_.id -eq $WorkPackage.id }) {
        return $false
    }
    $favorites += [pscustomobject]@{
        id      = $WorkPackage.id
        subject = Select-FirstValue $WorkPackage.subject '?'
        project = Select-FirstValue $WorkPackage._embedded.project.name '?'
    }
    Save-Favorite $favorites
    return $true
}


function Remove-Favorite($WorkPackageId) {
    # Remove WP from favorites by ID. Returns $true if something was removed.
    $favorites = @(Get-Favorite)
    $new = @($favorites | Where-Object { $_.id -ne $WorkPackageId })
    Save-Favorite $new
    return $new.Count -lt $favorites.Count
}


# ── Configuration ─────────────────────────────────────────────────────────────

$DotEnv = @{}


function Read-DotEnv {
    # Like python-dotenv's load_dotenv(): use the nearest .env, searching upwards from the script directory.
    $values = @{}
    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    while ($dir) {
        $path = Join-Path $dir '.env'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            foreach ($line in [IO.File]::ReadAllLines($path)) {
                if ($line -match '^\s*(?:export\s+)?([\w.]+)\s*=\s*(.*?)\s*$') {
                    $key, $value = $Matches[1], $Matches[2]
                    if ($value -match '^([''"])(.*)\1$') {
                        $value = $Matches[2]
                    } else {
                        $value = $value -replace '\s+#.*$', ''
                    }
                    $values[$key] = $value
                }
            }
            break
        }
        $dir = Split-Path -Parent $dir
    }
    return $values
}


function Get-Setting([string]$Name) {
    # Environment variables win over .env values, as with load_dotenv().
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -ne $value) { return $value }
    return $script:DotEnv[$Name]
}


function Get-Config {
    $script:DotEnv = Read-DotEnv
    $url       = "$(Get-Setting 'OPENPROJECT_URL')".TrimEnd('/')
    $token     = "$(Get-Setting 'OPENPROJECT_TOKEN')"
    $verifySsl = $false

    if (-not $url) {
        $url   = (Read-Input 'OpenProject URL (e.g. https://your-instance.openproject.com): ').TrimEnd('/')
    }
    if (-not $token) {
        $token = Read-Input 'Your API token: '
    }

    return $url, $token, $verifySsl
}


# ── API helpers ───────────────────────────────────────────────────────────────

function Disable-CertificateValidation {
    # Windows PowerShell 5.1 has no -SkipCertificateCheck, so trust every certificate process-wide.
    if (-not ('TrustAllCertificates' -as [type])) {
        Add-Type -TypeDefinition @'
public static class TrustAllCertificates {
    public static void Enable() {
        System.Net.ServicePointManager.ServerCertificateValidationCallback = (sender, certificate, chain, errors) => true;
    }
}
'@
    }
    ('TrustAllCertificates' -as [type])::Enable()
}


function New-OpenProjectApi([string]$BaseUrl, [string]$Token, [bool]$VerifySsl = $true) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 may still default to TLS 1.0 only.
        $protocols = [Net.ServicePointManager]::SecurityProtocol
        if ($protocols -ne [Net.SecurityProtocolType]::SystemDefault) {
            [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
        }
        if (-not $VerifySsl) {
            Disable-CertificateValidation
        }
    }
    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("apikey:$Token"))
    return [pscustomobject]@{
        Base      = $BaseUrl
        Headers   = @{ Authorization = "Basic $auth" }
        VerifySsl = $VerifySsl
    }
}


function Invoke-OpenProjectApi($Api, [string]$Method, [string]$Path, $Params, $Payload) {
    $uri = "$($Api.Base)/api/v3$Path"
    if ($Params) {
        $query = foreach ($key in $Params.Keys) {
            [Uri]::EscapeDataString($key) + '=' + [Uri]::EscapeDataString([string]$Params[$key])
        }
        $uri += '?' + ($query -join '&')
    }
    $request = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $Api.Headers
        ContentType     = 'application/json; charset=utf-8'
        UseBasicParsing = $true
    }
    if ($null -ne $Payload) {
        # Send bytes so non-ASCII comments survive Windows PowerShell's default body encoding.
        $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Payload -Depth 10 -Compress))
    }
    if (-not $Api.VerifySsl -and $PSVersionTable.PSVersion.Major -ge 6) {
        $request.SkipCertificateCheck = $true
    }
    return Invoke-RestMethod @request
}


function Get-CurrentUser($Api) {
    return Invoke-OpenProjectApi $Api GET '/users/me'
}


function Get-TimeEntry($Api, $UserId, [datetime]$FromDate, [datetime]$ToDate) {
    $offset   = 1
    $pageSize = 100
    $filters  = ConvertTo-Json -Depth 5 -Compress -InputObject @(
        @{ user_id  = @{ operator = '=';   values = @([string]$UserId) } }
        @{ spent_on = @{ operator = '<>d'; values = @((Format-IsoDate $FromDate), (Format-IsoDate $ToDate)) } }
    )
    while ($true) {
        $data = Invoke-OpenProjectApi $Api GET '/time_entries' -Params @{
            filters  = $filters
            offset   = $offset
            pageSize = $pageSize
        }
        foreach ($e in $data._embedded.elements) { $e }
        if ($offset * $pageSize -ge [int]$data.total) {
            break
        }
        $offset++
    }
}


function Search-WorkPackage($Api, [string]$Query) {
    $filters = ConvertTo-Json -Depth 5 -Compress -InputObject @(
        @{ subject = @{ operator = '~'; values = @($Query) } }
    )
    $data = Invoke-OpenProjectApi $Api GET '/work_packages' -Params @{
        filters  = $filters
        pageSize = 20
    }
    foreach ($wp in $data._embedded.elements) { $wp }
}


function Get-WorkPackage($Api, $WorkPackageId) {
    return Invoke-OpenProjectApi $Api GET "/work_packages/$WorkPackageId"
}


function Add-TimeEntry($Api, $WorkPackageId, [datetime]$SpentOn, [double]$Hours, [string]$Comment = '') {
    $payload = @{
        _links  = @{
            workPackage = @{ href = "/api/v3/work_packages/$WorkPackageId" }
            activity    = @{ href = "/api/v3/time_entries/activities/$ACTIVITY_ID" }
        }
        hours   = 'PT' + $Hours.ToString([cultureinfo]::InvariantCulture) + 'H'
        spentOn = Format-IsoDate $SpentOn
        comment = @{ raw = $Comment }
    }
    return Invoke-OpenProjectApi $Api POST '/time_entries' -Payload $payload
}


# ── Time-entry analysis ───────────────────────────────────────────────────────

function ConvertTo-Double([string]$Text) {
    return [double]::Parse($Text, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture)
}


function ConvertFrom-IsoDuration([string]$IsoDuration) {
    $IsoDuration = $IsoDuration.ToUpperInvariant().TrimStart('P')
    $hours = $minutes = 0.0
    if ($IsoDuration.Contains('T')) {
        $IsoDuration = $IsoDuration.Split('T')[1]
    }
    if ($IsoDuration.Contains('H')) {
        $parts       = $IsoDuration.Split('H')
        $hours       = ConvertTo-Double $parts[0]
        $IsoDuration = $parts[1]
    }
    if ($IsoDuration.Contains('M')) {
        $minutes = ConvertTo-Double $IsoDuration.Replace('M', '')
    }
    return $hours + $minutes / 60
}


function Group-EntryByDay($Entries) {
    $grouped = @{}
    foreach ($e in $Entries) {
        $day = Select-FirstValue $e.spentOn 'unknown'
        if (-not $grouped.ContainsKey($day)) {
            $grouped[$day] = [Collections.Generic.List[object]]::new()
        }
        $grouped[$day].Add($e)
    }
    return $grouped
}


function Get-UnfilledDay(
    $Grouped,
    [datetime]$FromDate,
    [datetime]$ToDate,
    [double]$MinHours = 8.0,
    [bool]$SkipWeekends = $true
) {
    $current = $FromDate
    while ($current -le $ToDate) {
        if ($SkipWeekends -and $current.DayOfWeek -in [DayOfWeek]::Saturday, [DayOfWeek]::Sunday) {
            $current = $current.AddDays(1)
            continue
        }
        $dayStr     = Format-IsoDate $current
        $dayEntries = @()
        if ($Grouped.ContainsKey($dayStr)) {
            $dayEntries = $Grouped[$dayStr].ToArray()
        }
        $total = 0.0
        foreach ($e in $dayEntries) {
            $total += ConvertFrom-IsoDuration (Select-FirstValue $e.hours 'PT0H')
        }
        if ($total -lt $MinHours) {
            [pscustomobject]@{ Date = $current; Entries = $dayEntries; Total = $total }
        }
        $current = $current.AddDays(1)
    }
}


# ── Display helpers ───────────────────────────────────────────────────────────

$ESC    = [char]27
$RESET  = "$ESC[0m"
$BOLD   = "$ESC[1m"
$CYAN   = "$ESC[96m"
$YELLOW = "$ESC[93m"
$GREEN  = "$ESC[92m"
$RED    = "$ESC[91m"
$DIM    = "$ESC[2m"
$GOLD   = "$ESC[33m"


function Format-Hours([double]$Hours) {
    return $Hours.ToString('F1', [cultureinfo]::InvariantCulture) + 'h'
}


function Get-EntryLabel($Entry) {
    $subject = Select-FirstValue $Entry._embedded.workPackage.subject $Entry.comment.raw '—'
    $hours   = ConvertFrom-IsoDuration (Select-FirstValue $Entry.hours 'PT0H')
    return "$subject ($(Format-Hours $hours))"
}


function Write-Header([string]$Text) {
    $line = '─' * 60
    Write-Host "`n${BOLD}${CYAN}${line}${RESET}"
    Write-Host "${BOLD}${CYAN}  ${Text}${RESET}"
    Write-Host "${BOLD}${CYAN}${line}${RESET}`n"
}


function Write-UnfilledDay($Days) {
    if (-not $Days) {
        Write-Host "${GREEN}  ✓ All days are filled!${RESET}`n"
        return
    }
    $i = 0
    foreach ($day in $Days) {
        $i++
        $barFilled = [int][Math]::Floor($day.Total / 8 * 20)
        $bar       = ('█' * $barFilled) + ('░' * (20 - $barFilled))
        $color     = if ($day.Total -eq 0) { $RED } else { $YELLOW }
        Write-Host ('  {0}[{1,2}]{2}  {3}  {4}{5} {6}/8h{2}' -f
            $BOLD, $i, $RESET, (Format-DisplayDate $day.Date), $color, $bar, (Format-Hours $day.Total))
        if ($day.Entries.Count) {
            foreach ($e in $day.Entries) {
                Write-Host "         ${DIM}• $(Get-EntryLabel $e)${RESET}"
            }
        } else {
            Write-Host "         ${DIM}(no entries)${RESET}"
        }
    }
    Write-Host ''
}


function Write-FavoriteList($Favorites) {
    if (-not $Favorites) {
        Write-Host "  ${DIM}(no favorites saved yet)${RESET}`n"
        return
    }
    $i = 0
    foreach ($f in $Favorites) {
        $i++
        Write-Host ('  {0}★{1} {2}[{3,2}]{1}  #{4}  {5}  {6}({7}){1}' -f
            $GOLD, $RESET, $BOLD, $i, $f.id, $f.subject, $DIM, $f.project)
    }
    Write-Host ''
}


# ── Work-package pickers ──────────────────────────────────────────────────────

function Select-SearchedWorkPackage($Api) {
    $query = Read-Input 'Search keyword: '
    if (-not $query) {
        return $null
    }
    Write-Host "`n${DIM}Searching…${RESET}"
    $wps = @(Search-WorkPackage $Api $query)
    if (-not $wps) {
        Write-Host "${RED}No work packages found.${RESET}"
        return $null
    }
    Write-Host ''
    $i = 0
    foreach ($wp in $wps) {
        $i++
        $project = Select-FirstValue $wp._embedded.project.name '?'
        Write-Host ('  {0}[{1,2}]{2}  #{3}  {4}  {5}({6}){2}' -f
            $BOLD, $i, $RESET, $wp.id, $wp.subject, $DIM, $project)
    }
    Write-Host ''
    while ($true) {
        $raw = Read-Input "Select (1-$($wps.Count)) or ${BOLD}q${RESET}: "
        if ($raw -eq 'q') {
            return $null
        }
        $index = ConvertTo-MenuIndex $raw $wps.Count
        if ($index -ge 0) {
            return $wps[$index]
        }
        Write-Host "${RED}Invalid.${RESET}"
    }
}


function Read-WorkPackageId($Api) {
    $raw = Read-Input 'Work Package ID: '
    if ($raw -notmatch '^[0-9]{1,18}$') {
        Write-Host "${RED}Not a valid ID.${RESET}"
        return $null
    }
    try {
        return Get-WorkPackage $Api ([long]$raw)
    } catch {
        Write-Host "${RED}Error fetching WP: $($_.Exception.Message)${RESET}"
        return $null
    }
}


function Select-FavoriteWorkPackage($Api) {
    $favorites = @(Get-Favorite)
    Write-Host ''
    Write-FavoriteList $favorites
    while ($true) {
        $raw = Read-Input "Select favorite (1-$($favorites.Count)) or ${BOLD}q${RESET}: "
        if ($raw -eq 'q') {
            return $null
        }
        $index = ConvertTo-MenuIndex $raw $favorites.Count
        if ($index -ge 0) {
            $fav = $favorites[$index]
            try {
                return Get-WorkPackage $Api $fav.id
            } catch {
                Write-Host "${RED}Error fetching WP #$($fav.id): $($_.Exception.Message)${RESET}"
                return $null
            }
        }
        Write-Host "${RED}Invalid.${RESET}"
    }
}


function Select-WorkPackage($Api) {
    # Full WP picker with favorites / search / ID options.
    $favorites = @(Get-Favorite)

    Write-Header 'Select a Work Package'

    if ($favorites) {
        Write-Host "  ${BOLD}[f]${RESET}  ${GOLD}★${RESET}  Pick from favorites  ${DIM}($($favorites.Count) saved)${RESET}"
    }
    Write-Host "  ${BOLD}[s]${RESET}     Search by keyword"
    Write-Host "  ${BOLD}[i]${RESET}     Enter Work Package ID directly"
    Write-Host "  ${BOLD}[q]${RESET}     Cancel`n"

    $valid = @('s', 'i', 'q')
    if ($favorites) {
        $valid += 'f'
    }
    while ($true) {
        $choice = Read-Input 'Choice: '
        if ($choice -in $valid) {
            break
        }
        Write-Host "${RED}Invalid.${RESET}"
    }

    switch ($choice) {
        'q' { return $null }
        'f' { return Select-FavoriteWorkPackage $Api }
        's' { return Select-SearchedWorkPackage $Api }
        'i' { return Read-WorkPackageId $Api }
    }
    return $null
}


# ── Favorites management screen ───────────────────────────────────────────────

function Edit-Favorite($Api) {
    while ($true) {
        Write-Header "${GOLD}★${RESET}  Manage Favorite Work Packages"
        $favorites = @(Get-Favorite)
        Write-FavoriteList $favorites

        Write-Host "  ${BOLD}[a]${RESET}  Add a favorite"
        if ($favorites) {
            Write-Host "  ${BOLD}[r]${RESET}  Remove a favorite"
        }
        Write-Host "  ${BOLD}[b]${RESET}  Back`n"

        $choice = Read-Input 'Choice: '

        if ($choice -eq 'b') {
            break
        }
        elseif ($choice -eq 'a') {
            Write-Header 'Add to Favorites – Find a Work Package'
            Write-Host "  ${BOLD}[s]${RESET}  Search by keyword"
            Write-Host "  ${BOLD}[i]${RESET}  Enter Work Package ID directly"
            Write-Host "  ${BOLD}[q]${RESET}  Cancel`n"
            $sub = Read-Input 'Choice: '
            $wp = $null
            if ($sub -eq 's') {
                $wp = Select-SearchedWorkPackage $Api
            } elseif ($sub -eq 'i') {
                $wp = Read-WorkPackageId $Api
            }
            if ($wp) {
                if (Add-Favorite $wp) {
                    Write-Host "`n${GREEN}✓ Added #$($wp.id) `"$($wp.subject)`" to favorites.${RESET}`n"
                } else {
                    Write-Host "`n${YELLOW}Already in favorites.${RESET}`n"
                }
            }
        }
        elseif ($choice -eq 'r' -and $favorites) {
            while ($true) {
                $raw = Read-Input "Remove number (1-$($favorites.Count)) or ${BOLD}q${RESET}: "
                if ($raw -eq 'q') {
                    break
                }
                $index = ConvertTo-MenuIndex $raw $favorites.Count
                if ($index -ge 0) {
                    $f = $favorites[$index]
                    $null = Remove-Favorite $f.id
                    Write-Host "`n${GREEN}✓ Removed #$($f.id) `"$($f.subject)`" from favorites.${RESET}`n"
                    break
                }
                Write-Host "${RED}Invalid.${RESET}"
            }
        }
        else {
            Write-Host "${RED}Invalid.${RESET}"
        }
    }
}


# ── Log hours flow ────────────────────────────────────────────────────────────

function Invoke-LogHoursFlow($Api, [datetime]$Day, [double]$ExistingTotal) {
    $wp = Select-WorkPackage $Api
    if (-not $wp) {
        return
    }

    $remaining = [Math]::Max(0.0, 8.0 - $ExistingTotal)

    Write-Host "`n  Work Package   : ${BOLD}#$($wp.id) $($wp.subject)${RESET}"
    Write-Host "  Activity       : ${BOLD}${ACTIVITY_NAME}${RESET}  ${DIM}(id ${ACTIVITY_ID})${RESET}"
    Write-Host "  Date           : ${BOLD}$(Format-DisplayDate $Day)${RESET}"
    Write-Host "  Already logged : $(Format-Hours $ExistingTotal)  |  Remaining to 8h: $(Format-Hours $remaining)`n"

    while ($true) {
        $raw = Read-Input "Hours to log (e.g. 3.5) [$(Format-Hours $remaining) suggested]: "
        if (-not $raw) {
            $hours = $remaining
            break
        }
        $hours = 0.0
        if ([double]::TryParse($raw, [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$hours)) {
            if ($hours -gt 0) {
                break
            }
            Write-Host "${RED}Must be positive.${RESET}"
        } else {
            Write-Host "${RED}Enter a number.${RESET}"
        }
    }

    $comment = Read-Input 'Comment (optional): '

    # Offer to save as favorite (only if not already saved)
    $favorites = @(Get-Favorite)
    if (-not ($favorites | Where-Object { $_.id -eq $wp.id })) {
        if ((Read-Input "Add #$($wp.id) to favorites? (y/N): ") -eq 'y') {
            $null = Add-Favorite $wp
            Write-Host "${GREEN}✓ Saved to favorites.${RESET}"
        }
    }

    Write-Host "`n${DIM}Logging $(Format-Hours $hours) to #$($wp.id)…${RESET}"
    try {
        $result = Add-TimeEntry $Api $wp.id $Day $hours $comment
        Write-Host "${GREEN}✓ Time entry created (ID $(Select-FirstValue $result.id '?'))${RESET}`n"
    } catch {
        Write-Host "${RED}Failed to log time: $($_.Exception.Message)${RESET}`n"
        if ($_.ErrorDetails.Message) {
            Write-Host $_.ErrorDetails.Message
        }
    }
}


# ── Day picker ────────────────────────────────────────────────────────────────

function Select-Day($Days) {
    Write-Header 'Select an unfilled day'
    Write-UnfilledDay $Days
    while ($true) {
        $raw = Read-Input (
            "Day number (1-$($Days.Count)), " +
            "${BOLD}f${RESET} = manage favorites, " +
            "${BOLD}q${RESET} = quit: "
        )
        if ($raw -eq 'q') {
            return $null
        }
        if ($raw -eq 'f') {
            return 'favorites'  # sentinel value
        }
        $index = ConvertTo-MenuIndex $raw $Days.Count
        if ($index -ge 0) {
            return $Days[$index]
        }
        Write-Host "${RED}Invalid choice.${RESET}"
    }
}


# ── Main ──────────────────────────────────────────────────────────────────────

function Invoke-Main {
    Write-Host "`n${BOLD}OpenProject Time Tracker${RESET}"
    Write-Host "${DIM}─────────────────────────────────────────────────${RESET}`n"

    $baseUrl, $token, $verifySsl = Get-Config

    if (-not $verifySsl) {
        Write-Host "${YELLOW}⚠ SSL verification disabled.${RESET}"
    } elseif ($null -eq (Get-Setting 'OPENPROJECT_VERIFY_SSL')) {
        if ((Read-Input 'Disable SSL certificate verification? (y/N): ') -eq 'y') {
            $verifySsl = $false
            Write-Host "${YELLOW}⚠ SSL verification disabled.${RESET}"
        }
    }

    $api = New-OpenProjectApi $baseUrl $token $verifySsl

    Write-Host "`n${DIM}Connecting…${RESET}"
    try {
        $me = Get-CurrentUser $api
    } catch {
        Write-Host "${RED}Authentication failed: $($_.Exception.Message)${RESET}"
        exit 1
    }

    $name = Select-FirstValue $me.name $me.login 'Unknown'
    Write-Host "${GREEN}✓ Logged in as ${BOLD}${name}${RESET}"
    Write-Host "  Activity hardcoded: ${BOLD}${ACTIVITY_NAME}${RESET} ${DIM}(id ${ACTIVITY_ID})${RESET}`n"

    # ── Date range ────────────────────────────────────────────────────────────
    $today       = [datetime]::Today
    $defaultFrom = $today.AddDays(1 - $today.Day)
    Write-Host "  Scanning from ${BOLD}$(Format-IsoDate $defaultFrom)${RESET} to ${BOLD}$(Format-IsoDate $today)${RESET}"
    if ((Read-Input '  Use a different range? (y/N): ') -eq 'y') {
        try {
            $fromDate = ConvertFrom-IsoDate (Read-Input '  From (YYYY-MM-DD): ')
            $toDate   = ConvertFrom-IsoDate (Read-Input '  To   (YYYY-MM-DD): ')
        } catch {
            Write-Host "${RED}Invalid date format.${RESET}"
            exit 1
        }
    } else {
        $fromDate, $toDate = $defaultFrom, $today
    }

    $skipWeekends = (Read-Input '  Skip weekends? (Y/n): ') -ne 'n'

    # ── Fetch entries ─────────────────────────────────────────────────────────
    Write-Host "`n${DIM}Fetching time entries…${RESET}"
    try {
        $entries = @(Get-TimeEntry $api $me.id $fromDate $toDate)
    } catch {
        Write-Host "${RED}Error fetching entries: $($_.Exception.Message)${RESET}"
        exit 1
    }

    $grouped  = Group-EntryByDay $entries
    $unfilled = @(Get-UnfilledDay $grouped $fromDate $toDate -SkipWeekends $skipWeekends)

    Write-Host "  Found $($entries.Count) entries across $($grouped.Count) days."
    Write-Host "  ${YELLOW}$($unfilled.Count) day(s) below 8h threshold.${RESET}`n"

    if (-not $unfilled) {
        Write-Host "${GREEN}Great — no unfilled days in this period!${RESET}`n"
        if ((Read-Input 'Manage favorites? (y/N): ') -eq 'y') {
            Edit-Favorite $api
        }
        return
    }

    # ── Main interaction loop ─────────────────────────────────────────────────
    while ($true) {
        $selected = Select-Day $unfilled

        if ($null -eq $selected) {
            break
        }

        if ($selected -eq 'favorites') {
            Edit-Favorite $api
            continue
        }

        Write-Host "`n  Selected: ${BOLD}$(Format-DisplayDate $selected.Date)${RESET}  ($(Format-Hours $selected.Total) logged)`n"

        Invoke-LogHoursFlow $api $selected.Date $selected.Total

        # Refresh
        Write-Host "${DIM}Refreshing entries…${RESET}"
        try {
            $entries  = @(Get-TimeEntry $api $me.id $fromDate $toDate)
            $grouped  = Group-EntryByDay $entries
            $unfilled = @(Get-UnfilledDay $grouped $fromDate $toDate -SkipWeekends $skipWeekends)
        } catch {
            # Keep the previous list if the refresh fails.
        }

        if (-not $unfilled) {
            Write-Host "`n${GREEN}🎉 All days are now filled!${RESET}`n"
            break
        }

        if ((Read-Input 'Log more hours? (Y/n): ') -eq 'n') {
            break
        }
    }

    Write-Host "`n${DIM}Bye!${RESET}`n"
}


# Run only when executed, not when dot-sourced.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
