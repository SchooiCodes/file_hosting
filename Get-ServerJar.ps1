param(
    [Parameter(Mandatory=$true)][ValidateSet("V","P","F")][string]$Provider,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutFile
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# All three APIs either require or recommend a descriptive User-Agent.
$UserAgent = "my-server-installer/1.0 (local script; no contact url)"

function Fail($msg) {
    exit 1
}

switch ($Provider) {

    "V" {
        # Vanilla: walk the version manifest to find this version's own
        # metadata json, which contains the real (hashed) server jar URL.
        $manifest = Invoke-RestMethod -Uri "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" -UserAgent $UserAgent
        $entry = $manifest.versions | Where-Object { $_.id -eq $Version }
        if (-not $entry) { Fail "Minecraft version '$Version' was not found in Mojang's manifest." }

        $versionMeta = Invoke-RestMethod -Uri $entry.url -UserAgent $UserAgent
        $serverUrl = $versionMeta.downloads.server.url
        if (-not $serverUrl) { Fail "No server jar exists for version '$Version' (some very old/odd versions don't have one)." }

        Invoke-WebRequest -Uri $serverUrl -OutFile $OutFile -UserAgent $UserAgent
    }

    "P" {
        # Paper: query the Fill API for builds of this MC version, prefer
        # the newest STABLE build, and pull its "server:default" download.
        $buildsUrl = "https://fill.papermc.io/v3/projects/paper/versions/$Version/builds"
        try {
            $builds = Invoke-RestMethod -Uri $buildsUrl -UserAgent $UserAgent -ErrorAction Stop
        } catch {
            Fail "No Paper builds found for Minecraft version '$Version'."
        }
        if (-not $builds -or $builds.Count -eq 0) { Fail "No Paper builds found for Minecraft version '$Version'." }

        $stable = $builds | Where-Object { $_.channel -eq "STABLE" } | Sort-Object id -Descending | Select-Object -First 1
        $build = if ($stable) { $stable } else { $builds | Sort-Object id -Descending | Select-Object -First 1 }
        $downloadUrl = $build.downloads.'server:default'.url
        if (-not $downloadUrl) { Fail "Paper build $($build.id) has no server download available." }

        Invoke-WebRequest -Uri $downloadUrl -OutFile $OutFile -UserAgent $UserAgent
    }

    "F" {
        # Fabric: the download URL is built from three parts: game version,
        # latest stable loader version, and latest stable installer version.
        $loaders = Invoke-RestMethod -Uri "https://meta.fabricmc.net/v2/versions/loader/$Version" -UserAgent $UserAgent
        if (-not $loaders -or $loaders.Count -eq 0) { Fail "Fabric has no loader builds for Minecraft version '$Version'." }

        $loaderEntry = $loaders | Where-Object { $_.loader.stable } | Select-Object -First 1
        if (-not $loaderEntry) { $loaderEntry = $loaders[0] }
        $loaderVersion = $loaderEntry.loader.version

        $installers = Invoke-RestMethod -Uri "https://meta.fabricmc.net/v2/versions/installer" -UserAgent $UserAgent
        $installerEntry = $installers | Where-Object { $_.stable } | Select-Object -First 1
        if (-not $installerEntry) { $installerEntry = $installers[0] }
        $installerVersion = $installerEntry.version

        $downloadUrl = "https://meta.fabricmc.net/v2/versions/loader/$Version/$loaderVersion/$installerVersion/server/jar"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $OutFile -UserAgent $UserAgent
    }
}