param (
    [string]$webhookUrl = "https://discord.com/api/webhooks/1269631587645919345/7q9Y1NyKus_Es6WSOlnY5rTnKDzJEEwINWbU_SWIb1nqdDqF2fYHzf4LnNLqhCsLEBqX",
    [string[]]$zipFiles
)

# Function to send a file via Discord webhook
function Send-FileToDiscord {
    param (
        [string]$filePath
    )

    if (-Not (Test-Path $filePath)) {
        Write-Error "The file '$filePath' does not exist."
        return
    }

    # Debugging output
    Write-Output "Sending file: $filePath"

    # Prepare the request
    $uri = $webhookUrl
    $boundary = [guid]::NewGuid().ToString()
    $headers = @{
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }

    # Read the file as byte array
    $fileBytes = [System.IO.File]::ReadAllBytes($filePath)

    # Prepare the body of the request
    $body = @"
--$boundary
Content-Disposition: form-data; name="file"; filename="$(Split-Path $filePath -Leaf)"
Content-Type: application/zip

$([System.Text.Encoding]::UTF8.GetString($fileBytes))
--$boundary--
"@

    # Send the request
    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
}

# Ensure $zipFiles is an array of file paths
$zipFilesArray = $zipFiles -split ','

# Debugging output
Write-Output "Zip files to send:"
$zipFilesArray | ForEach-Object { Write-Output $_ }

# Send each file
foreach ($file in $zipFilesArray) {
    Send-FileToDiscord -filePath $file
}
