# MagicMouseScroll.ps1
# F² - MIT License
#
# Makes an Apple Magic Mouse scroll on Windows 10/11 by registering Apple's
# own Microsoft-WHQL-signed Boot Camp driver (applewirelessmouse.sys,
# 6.0.6200.0) as a LowerFilter under hidbth on the mouse's Bluetooth HID
# device instance.
#
# Apple's binary is NOT shipped. It is downloaded at install time from
# Apple's own CDN (BootCampESD.pkg), extracted, hash- and signature-verified
# before anything is touched. No test signing, no Secure Boot change.
#
# Usage:  .\MagicMouseScroll.ps1 [-Install|-Uninstall|-Status|-DownloadOnly]
#         -DriverPath <sys>   use a locally supplied driver instead of download
#         -WorkDir <dir>      scratch/download dir (default $env:TEMP\MagicMouseScroll)
#         -InstanceId <id>    override automatic device detection
#         -Portable7Zip       ignore installed 7-Zip, always use the portable one
#         -Yes                skip the confirmation prompt

#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,
    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,
    [Parameter(ParameterSetName = 'DownloadOnly')]
    [switch]$DownloadOnly,

    [string]$DriverPath,
    [string]$WorkDir = (Join-Path $env:TEMP 'MagicMouseScroll'),
    [string]$InstanceId,
    [switch]$Portable7Zip,
    [switch]$Yes,
    [Parameter(DontShow = $true)]
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- constants
$script:ServiceName   = 'applewirelessmouse'
$script:ServiceDesc   = 'Apple Wireless Mouse'
$script:DestSys       = Join-Path $env:SystemRoot "System32\drivers\$ServiceName.sys"
$script:ExpectedSha256 = 'EEA7CEE897A04FE4617E93BE2E420EB7F40E89D6A1686101E1E060DDAD2BD564'
$script:ExpectedVersion = '6.0.6200.0'
$script:ExpectedSigner  = 'Microsoft Windows Hardware Compatibility Publisher'
$script:SucatalogUrl = 'https://swscan.apple.com/content/catalogs/others/index-11-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog'
$script:SevenZrUrl   = 'https://www.7-zip.org/a/7zr.exe'
$script:SevenZrSha256 = '256FECA8E274E5DA655E2A284FABAFD9F554365EB164862089DACD4E8276D282'
$script:SevenZPkgUrl = 'https://www.7-zip.org/a/7z2409-x64.exe'
$script:SevenZPkgSha256 = 'BDD1A33DE78618D16EE4CE148B849932C05D0015491C34887846D431D29F308E'
$script:BackupDir    = Join-Path $env:ProgramData 'Fsquared\MagicMouseScroll'   # ASCII folder name on purpose
$script:KnownPids    = @('030D', '0310', '0269', '0323')
$script:BthEnumBase  = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}'

# ------------------------------------------------------------------- output
function Out-Ok   { param([string]$m) Write-Host "[ok] $m" -ForegroundColor Green }
function Out-Step { param([string]$m) Write-Host "[..] $m" -ForegroundColor Cyan }
function Out-Bad  { param([string]$m) Write-Host "[!!] $m" -ForegroundColor Yellow }
function Die      { param([string]$m) throw $m }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return [Security.Principal.WindowsPrincipal]::new($id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------- plist walker
function Get-PlistValue {
    param([System.Xml.XmlElement]$Dict, [string]$Key)
    $kids = @($Dict.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })
    for ($i = 0; $i -lt ($kids.Count - 1); $i += 2) {
        if ($kids[$i].LocalName -eq 'key' -and $kids[$i].InnerText -eq $Key) {
            return $kids[$i + 1]
        }
    }
    return $null
}

function Get-PlistText {
    param([System.Xml.XmlElement]$Dict, [string]$Key)
    $el = Get-PlistValue -Dict $Dict -Key $Key
    if ($null -eq $el) { return $null }
    return $el.InnerText
}

# ---------------------------------------------------------------- download
function Save-File {
    param([string]$Url, [string]$Dest, [int64]$ExpectedSize = 0)
    if ((Test-Path $Dest) -and $ExpectedSize -gt 0 -and
        (Get-Item $Dest).Length -eq $ExpectedSize) {
        Out-Ok "already downloaded: $Dest ($ExpectedSize bytes)"
        return
    }
    if ($ExpectedSize -gt 0) {
        Out-Step ("downloading {0:N1} MB`n    $Url" -f ($ExpectedSize / 1MB))
    } else {
        Out-Step "downloading $Url"
    }
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    $len = (Get-Item $Dest).Length
    Out-Ok "downloaded $Dest ($len bytes)"
    if ($ExpectedSize -gt 0 -and $len -ne $ExpectedSize) {
        Die "size mismatch for $Dest : $len != $ExpectedSize"
    }
}

function Test-FileSha256 {
    param([string]$Path, [string]$Expected)
    $h = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($h -ne $Expected.ToUpper()) { Die "SHA-256 mismatch for $Path : $h" }
}

# ------------------------------------------------------------ driver verify
function Test-DriverFile {
    param([string]$Path)
    Test-FileSha256 -Path $Path -Expected $ExpectedSha256
    $ver = (Get-Item $Path).VersionInfo.FileVersion
    if ($ver -ne $ExpectedVersion) {
        Die "unexpected FileVersion for $Path : $ver (expected $ExpectedVersion)"
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        Die "Authenticode status for $Path is $($sig.Status), expected Valid"
    }
    if ($sig.SignerCertificate.Subject -notmatch $ExpectedSigner) {
        Die "unexpected signer for $Path : $($sig.SignerCertificate.Subject)"
    }
    Out-Ok "driver verified: sha256 match, FileVersion $ver, signer '$($sig.SignerCertificate.Subject.Split(',')[0])'"
}

# ----------------------------------------------------------------- 7-zip
function Get-SevenZip {
    if (-not $Portable7Zip) {
        $candidates = @()
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\7-Zip' -ErrorAction SilentlyContinue
        if ($reg -and $reg.Path) { $candidates += (Join-Path $reg.Path '7z.exe') }
        $candidates += (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
        $cmd = Get-Command 7z -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) {
                Out-Ok "using installed 7-Zip: $c"
                return $c
            }
        }
        Out-Step "no installed 7-Zip found, fetching a portable copy"
    } else {
        Out-Step "-Portable7Zip: using downloaded portable 7-Zip"
    }

    $zr  = Join-Path $WorkDir '7zr.exe'
    $pkg = Join-Path $WorkDir '7z2409-x64.exe'
    Save-File -Url $SevenZrUrl -Dest $zr
    Save-File -Url $SevenZPkgUrl -Dest $pkg
    Test-FileSha256 -Path $zr  -Expected $SevenZrSha256
    Test-FileSha256 -Path $pkg -Expected $SevenZPkgSha256

    $portableDir = Join-Path $WorkDir '7z'
    if (-not (Test-Path (Join-Path $portableDir '7z.exe'))) {
        Out-Step "extracting portable 7-Zip with 7zr"
        & $zr 'x' '-y' "-o$portableDir" $pkg '7z.exe' '7z.dll' | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "7zr extraction failed ($LASTEXITCODE)" }
    }
    $seven = Join-Path $portableDir '7z.exe'
    if (-not (Test-Path $seven)) { Die "portable 7z.exe missing after extraction" }
    Out-Ok "portable 7-Zip ready: $seven"
    return $seven
}

# ------------------------------------------------------- BootCampESD acquire
function Get-BootCampPackageInfo {
    Out-Step "fetching Apple software-update catalog"
    $catalogPath = Join-Path $WorkDir 'index.sucatalog'
    Save-File -Url $SucatalogUrl -Dest $catalogPath
    [xml]$plist = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8

    $products = Get-PlistValue -Dict $plist.plist.dict -Key 'Products'
    if ($null -eq $products) { Die 'sucatalog: no Products dict' }

    $kids = @($products.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })
    $best = $null
    for ($i = 0; $i -lt ($kids.Count - 1); $i += 2) {
        if ($kids[$i].LocalName -ne 'key') { continue }
        $prodId   = $kids[$i].InnerText
        $prodDict = $kids[$i + 1]
        $pkgs = Get-PlistValue -Dict $prodDict -Key 'Packages'
        if ($null -eq $pkgs) { continue }
        foreach ($pkg in $pkgs.ChildNodes) {
            $url = Get-PlistText -Dict $pkg -Key 'URL'
            if (-not $url -or $url -notmatch 'BootCampESD\.pkg$') { continue }
            $size = [int64](Get-PlistText -Dict $pkg -Key 'Size')
            if ($null -eq $best -or $size -lt $best.Size) {
                $best = [pscustomobject]@{ Id = $prodId; Url = $url; Size = $size }
            }
        }
    }
    if ($null -eq $best) { Die 'no BootCampESD.pkg found in catalog' }
    Out-Ok "selected product $($best.Id) ($([math]::Round($best.Size/1MB)) MB)"
    return $best
}

function Expand-BootCampDriver {
    param([string]$PkgPath)
    $seven = Get-SevenZip
    $extractRoot = Join-Path $WorkDir 'extract'

    # Each layer produces the next expected file; chain verified against the
    # real BootCampESD layout: pkg -> Payload~ -> WindowsSupport.dmg ->
    # AppleWirelessMouse64.exe -> AppleWirelessMouse.sys
    $layers = @(
        'Payload*',
        'WindowsSupport.dmg',
        'AppleWirelessMouse64.exe',
        'AppleWirelessMouse.sys'
    )
    $queue = @(Get-Item -LiteralPath $PkgPath)
    for ($i = 0; $i -lt $layers.Count; $i++) {
        $found = @()
        foreach ($arc in $queue) {
            $outDir = Join-Path $extractRoot ("L{0}_{1}" -f $i, ($arc.BaseName -replace '[^\w\.-]', '_'))
            $marker = Join-Path $outDir '.done'
            if (-not (Test-Path $marker)) {
                New-Item -ItemType Directory -Force $outDir | Out-Null
                Out-Step "7z x $($arc.Name) -> $outDir"
                & $seven 'x' $arc.FullName "-o$outDir" '-y' | Out-Null
                if ($LASTEXITCODE -ne 0) { Die "7z failed on $($arc.Name) ($LASTEXITCODE)" }
                New-Item -ItemType File -Force $marker | Out-Null
            }
            $found += Get-ChildItem -LiteralPath $outDir -Recurse -File -Filter $layers[$i]
        }
        if ($found.Count -eq 0) {
            Die "extraction chain broke: '$($layers[$i])' not found under $extractRoot"
        }
        Out-Ok "layer $i : found $($found[0].FullName.Substring($extractRoot.Length + 1))"
        $queue = @($found[0])
    }
    $sys = $queue[0].FullName
    $srcDir = Split-Path $sys -Parent

    # stage .sys + .inf + license next to each other in WorkDir\driver
    $stage = Join-Path $WorkDir 'driver'
    New-Item -ItemType Directory -Force $stage | Out-Null
    foreach ($name in @('AppleWirelessMouse.sys', 'AppleWirelessMouse.inf', 'EnglishLicense.txt')) {
        $src = Join-Path $srcDir $name
        if (Test-Path $src) { Copy-Item $src $stage -Force }
    }
    $staged = Join-Path $stage 'AppleWirelessMouse.sys'
    if (-not (Test-Path $staged)) { Die "staged driver missing at $staged" }
    Out-Ok "driver staged at $staged"
    Out-Step "note: AppleWirelessMouse.inf + EnglishLicense.txt are next to it - Apple's license applies to Apple's driver"
    return $staged
}

function Clear-WorkFiles {
    # Drop the big downloads/extractions (~1.6 GB); keep log + staged driver.
    $freed = 0
    foreach ($item in @((Join-Path $WorkDir 'extract'), (Join-Path $WorkDir 'index.sucatalog'),
                        (Join-Path $WorkDir '7z2409-x64.exe'), (Join-Path $WorkDir '7zr.exe'), (Join-Path $WorkDir '7z')) +
                      @(Get-ChildItem -LiteralPath $WorkDir -Filter 'BootCampESD-*.pkg' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
        if ($item -and (Test-Path -LiteralPath $item)) {
            $freed += (Get-ChildItem -LiteralPath $item -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($freed -gt 0) { Out-Ok ("removed {0:N0} MB of temporary download/extraction files from $WorkDir" -f ($freed / 1MB)) }
}

function Get-VerifiedDriver {
    # Returns a verified applewirelessmouse.sys path.
    if ($DriverPath) {
        $p = (Resolve-Path -LiteralPath $DriverPath).Path
        Out-Step "using local driver: $p"
        Test-DriverFile -Path $p
        return $p
    }
    $pkgInfo = Get-BootCampPackageInfo
    $pkgPath = Join-Path $WorkDir "BootCampESD-$($pkgInfo.Id).pkg"
    Save-File -Url $pkgInfo.Url -Dest $pkgPath -ExpectedSize $pkgInfo.Size
    $sys = Expand-BootCampDriver -PkgPath $pkgPath
    Test-DriverFile -Path $sys
    return $sys
}

# --------------------------------------------------------- device detection
function Get-DeviceChildren {
    param([string]$Id)
    $kids = @()
    $prop = Get-PnpDeviceProperty -InstanceId $Id -KeyName 'DEVPKEY_Device_Children' `
            -ErrorAction SilentlyContinue
    if ($prop -and $prop.Data) {
        foreach ($cid in @($prop.Data)) {
            $cd = Get-PnpDevice -InstanceId $cid -ErrorAction SilentlyContinue
            if ($cd) { $kids += $cd }
        }
    }
    return ,$kids
}

function Get-MagicMouseDevices {
    if ($InstanceId) {
        $d = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
        if (-not $d) { Die "device not found: $InstanceId" }
        return ,@($d)
    }
    $candidates = @(
        Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -like "$BthEnumBase`_VID&0001004C_PID&*" -or
            $_.InstanceId -like "$BthEnumBase`_VID&000205AC_PID&*"
        }
    )
    $hits = @()
    foreach ($dev in $candidates) {
        $pid4 = $null
        if ($dev.InstanceId -match 'PID&([0-9A-Fa-f]{4})') { $pid4 = $Matches[1].ToUpper() }
        $match = $pid4 -and ($KnownPids -contains $pid4)
        if (-not $match) {
            $kids = Get-DeviceChildren -Id $dev.InstanceId
            if (@($kids | Where-Object { $_.Class -eq 'Mouse' }).Count -gt 0) { $match = $true }
        }
        if ($match) { $hits += $dev }
    }
    return ,$hits
}

# -------------------------------------------------------------- registry ops
function Backup-DeviceState {
    param([string]$Id, [int]$Index = 0)
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$Id"
    $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = [ordered]@{
        InstanceId    = $Id
        LowerFilters  = @($props.LowerFilters | Where-Object { $_ })
        UpperFilters  = @($props.UpperFilters | Where-Object { $_ })
        Service       = $props.Service
    }
    $file = Join-Path $BackupDir "backup-$stamp$(if ($Index -gt 0) { "-$Index" }).json"
    $backup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
    Out-Ok "device state backed up to $file"
}

function Restart-DeviceNode {
    param([string]$Id)
    & pnputil.exe /restart-device "$Id" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Out-Step "pnputil /restart-device unsupported, using Disable/Enable-PnpDevice"
        Disable-PnpDevice -InstanceId $Id -Confirm:$false -ErrorAction Stop
        Enable-PnpDevice  -InstanceId $Id -Confirm:$false -ErrorAction Stop
    }
    $dev = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $dev = Get-PnpDevice -InstanceId $Id -ErrorAction SilentlyContinue
        if ($dev -and $dev.Status -eq 'OK') { break }
    }
    return $dev
}

function Show-DeviceStatus {
    param([string]$Id)
    $dev = Get-PnpDevice -InstanceId $Id -ErrorAction SilentlyContinue
    $prob = (Get-PnpDeviceProperty -InstanceId $Id -KeyName 'DEVPKEY_Device_ProblemCode' `
            -ErrorAction SilentlyContinue).Data
    Write-Host "    device   : $Id"
    Write-Host "    status   : $(if ($dev) { $dev.Status } else { 'gone' })  problemCode=$prob"
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Write-Host "    service  : $(if ($svc) { $svc.Status } else { 'not installed' })"
    $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$Id"
    $lf = (Get-ItemProperty -LiteralPath $key -Name 'LowerFilters' -ErrorAction SilentlyContinue).LowerFilters
    Write-Host "    filters  : $(if ($lf) { $lf -join ', ' } else { '(none)' })"
    $kids = Get-DeviceChildren -Id $Id
    if ($kids.Count) {
        Write-Host "    children :"
        foreach ($k in $kids) {
            Write-Host "      [$($k.Status)] $($k.Class) - $($k.FriendlyName)"
        }
    }
    return $dev
}

# --------------------------------------------------------------- install
function Install-MagicMouse {
    $devices = @(Get-MagicMouseDevices)
    if ($devices.Count -eq 0) {
        Die 'No Magic Mouse Bluetooth HID device found. Pair the mouse in Bluetooth settings first, then re-run.'
    }
    Out-Ok "found $($devices.Count) Magic Mouse device(s):"
    foreach ($d in $devices) { Write-Host "    $($d.InstanceId)  ($($d.FriendlyName), $($d.Status))" }

    $haveDriver = (Test-Path $DestSys) -and
        ((Get-FileHash $DestSys -Algorithm SHA256).Hash -eq $ExpectedSha256)
    if ($haveDriver) { Out-Ok "verified driver already installed at $DestSys - no download needed" }

    # confirmation (before anything is downloaded or changed)
    Write-Host ''
    Write-Host '    This will:'
    if (-not $haveDriver) {
        if ($DriverPath) { Write-Host "      - verify the driver at $DriverPath" }
        else { Write-Host "      - download Apple's Boot Camp package (~330 MB) from Apple's servers and extract the driver" }
    }
    Write-Host "      - copy the verified driver to $DestSys"
    Write-Host "      - create the '$ServiceName' kernel service (demand start)"
    foreach ($d in $devices) {
        Write-Host "      - add 'applewirelessmouse' to LowerFilters of $($d.InstanceId)"
    }
    Write-Host ''
    Write-Host '    Keep a second mouse or a keyboard at hand in case the stack fails.'
    if (-not $Yes) {
        $ans = Read-Host '    Proceed? [y/N]'
        if ($ans -notmatch '^(y|yes)$') { Die 'aborted by user' }
    }

    # driver source
    $sys = $null
    if (-not $haveDriver) { $sys = Get-VerifiedDriver }

    # binary + service
    if ($sys) {
        Copy-Item -LiteralPath $sys -Destination $DestSys -Force
        Out-Ok "driver copied to $DestSys"
    }
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        & sc.exe create $ServiceName 'type=' 'kernel' 'start=' 'demand' 'error=' 'ignore' `
           'binPath=' '\SystemRoot\System32\drivers\applewirelessmouse.sys' `
           'DisplayName=' "$ServiceDesc" | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "sc.exe create failed ($LASTEXITCODE)" }
        Out-Ok "service '$ServiceName' created"
    } else {
        Out-Ok "service '$ServiceName' already present"
    }

    # per-device lower filter
    $idx = 0
    foreach ($dev in $devices) {
        Backup-DeviceState -Id $dev.InstanceId -Index $idx
        $idx++

        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)"
        $existing = @((Get-ItemProperty -LiteralPath $key -Name 'LowerFilters' `
                      -ErrorAction SilentlyContinue).LowerFilters |
                      Where-Object { $_ -and $_ -ne $ServiceName })
        Set-ItemProperty -LiteralPath $key -Name 'LowerFilters' `
            -Value ([string[]]($existing + $ServiceName)) -Type MultiString
        Out-Ok "LowerFilters = $((Get-ItemProperty -LiteralPath $key).LowerFilters -join ', ') on $($dev.InstanceId)"

        Out-Step "restarting $($dev.InstanceId)"
        $dev2 = Restart-DeviceNode -Id $dev.InstanceId
        $d2 = Show-DeviceStatus -Id $dev.InstanceId
        if (-not $d2 -or $d2.Status -ne 'OK') {
            Out-Bad "device is NOT OK after restart - run: .\MagicMouseScroll.ps1 -Uninstall"
            Out-Bad "(use a keyboard or a second mouse if this one is dead)"
        }
    }
    Clear-WorkFiles
    Out-Ok 'install complete - try scrolling on the mouse surface now'
}

# ------------------------------------------------------------- uninstall
function Uninstall-MagicMouse {
    $devices = @(Get-MagicMouseDevices)
    if ($devices.Count -eq 0 -and -not $InstanceId) {
        Out-Step 'no matching device instances found (device may be absent)'
    }
    foreach ($dev in $devices) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)"
        $remaining = @((Get-ItemProperty -LiteralPath $key -Name 'LowerFilters' `
                       -ErrorAction SilentlyContinue).LowerFilters |
                       Where-Object { $_ -and $_ -ne $ServiceName })
        if ($remaining.Count -gt 0) {
            Set-ItemProperty -LiteralPath $key -Name 'LowerFilters' `
                -Value ([string[]]$remaining) -Type MultiString
            Out-Ok "LowerFilters on $($dev.InstanceId): $($remaining -join ', ')"
        } else {
            Remove-ItemProperty -LiteralPath $key -Name 'LowerFilters' -ErrorAction SilentlyContinue
            Out-Ok "LowerFilters removed on $($dev.InstanceId)"
        }
        Out-Step "restarting $($dev.InstanceId)"
        Restart-DeviceNode -Id $dev.InstanceId | Out-Null
        Show-DeviceStatus -Id $dev.InstanceId | Out-Null
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Out-Ok "service '$ServiceName' deleted (unloads on restart/removal)"
        } else {
            Out-Bad "sc.exe delete failed ($LASTEXITCODE)"
        }
    } else {
        Out-Ok "service '$ServiceName' not present"
    }
    if (Test-Path $DestSys) {
        try {
            Remove-Item -LiteralPath $DestSys -Force -ErrorAction Stop
            Out-Ok "removed $DestSys"
        } catch {
            Out-Bad "could not remove $DestSys (in use) - a reboot finishes removal"
        }
    }
    Out-Ok 'uninstall complete'
}

# ----------------------------------------------------------------- status
function Show-Status {
    $devices = @(Get-MagicMouseDevices)
    if ($devices.Count -eq 0) {
        Out-Step 'no Magic Mouse Bluetooth HID device instances found'
    }
    foreach ($dev in $devices) {
        Show-DeviceStatus -Id $dev.InstanceId | Out-Null
        Write-Host ''
    }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Write-Host "  service '$ServiceName': $(if ($svc) { $svc.Status } else { 'not installed' })"
    if (Test-Path $DestSys) {
        $match = (Get-FileHash $DestSys -Algorithm SHA256).Hash -eq $ExpectedSha256
        Write-Host "  driver file: $DestSys (sha256 match: $match)"
    } else {
        Write-Host "  driver file: not present at $DestSys"
    }
}

# ------------------------------------------------------------------- main
$action = $PSCmdlet.ParameterSetName

if (($action -eq 'Install' -or $action -eq 'Uninstall') -and -not (Test-Admin)) {
    Out-Step 'elevation required - relaunching as administrator'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                 '-File', "`"$PSCommandPath`"", "-$action", '-Elevated')
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -in 'Install', 'Uninstall', 'Status', 'DownloadOnly', 'Elevated') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += @("-$k", "`"$v`"") }
    }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                  -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        Die "elevation declined or failed: $($_.Exception.Message)"
    }
    exit $proc.ExitCode
}

New-Item -ItemType Directory -Force $WorkDir | Out-Null
$logFile = Join-Path $WorkDir 'MagicMouseScroll.log'
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }

$exitCode = 0
try {
    switch ($action) {
        'Install'      { Install-MagicMouse }
        'Uninstall'    { Uninstall-MagicMouse }
        'Status'       { Show-Status }
        'DownloadOnly' {
            $sys = Get-VerifiedDriver
            Out-Ok "verified driver: $sys"
        }
    }
} catch {
    Out-Bad $_.Exception.Message
    $exitCode = 1
}

try { Stop-Transcript | Out-Null } catch { }

if ($exitCode -ne 0) { Out-Bad "failed - transcript at $logFile" }
if ($Elevated) { Read-Host 'Press Enter to close' | Out-Null }
exit $exitCode
