$compress = @{
  Path = "$ENV:TEMP\wstemp\"
  CompressionLevel = "Fastest"
  DestinationPath = "$ENV:TEMP\wstemp\passes.zip"
}
Compress-Archive @compress
