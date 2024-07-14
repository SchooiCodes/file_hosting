$compress = @{
  Path = "$ENV:TEMP\wstemp\"
  CompressionLevel = "Fastest"
  DestinationPath = "$ENV:TEMP\wstemp\wifipasses.zip"
}
Compress-Archive @compress
