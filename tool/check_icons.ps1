Add-Type -AssemblyName System.Drawing
$paths = @(
  'assets/images/MintMusicLogo.png',
  'android/app/src/main/res/mipmap-hdpi/logo.png',
  'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
  'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png',
  'web/favicon.png'
)
foreach ($p in $paths) {
  if (-not (Test-Path $p)) { Write-Output "$p MISSING"; continue }
  $img = [System.Drawing.Bitmap]::FromFile((Resolve-Path $p))
  $w = $img.Width; $h = $img.Height
  $c1 = $img.GetPixel(2, 2)
  $c2 = $img.GetPixel([int]($w / 2), [int]($h / 2))
  $alpha = $img.GetPixel([int]($w / 2), [int]($h / 2)).A
  Write-Output ("{0}: {1}x{2} tl=({3},{4},{5},{6}) center=({7},{8},{9},{10})" -f $p, $w, $h, $c1.R, $c1.G, $c1.B, $c1.A, $c2.R, $c2.G, $c2.B, $alpha)
  $img.Dispose()
}