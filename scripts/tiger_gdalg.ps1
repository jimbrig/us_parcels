$outDir = "data/geoparquet/tiger/state=13/county=121"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = "$outDir/edges.parquet"

Write-Host "==> reading TIGER edges via GDALG + VSI..." -ForegroundColor Cyan
pixi run ogr2ogr -f Parquet `
  -lco COMPRESSION=ZSTD `
  -lco WRITE_COVERING_BBOX=YES `
  -progress `
  $out `
  pipelines/tiger/fulton_county_edges.gdalg.json

if ($LASTEXITCODE -eq 0) {
  $size = [math]::Round((Get-Item $out).Length / 1MB, 2)
  Write-Host "    wrote $out ($size MB)" -ForegroundColor Green
} else {
  Write-Host "    pipeline failed" -ForegroundColor Red; exit 1
}
