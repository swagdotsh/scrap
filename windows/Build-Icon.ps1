$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$scrapRoot = Split-Path $PSScriptRoot -Parent
$scrapSource = Join-Path $scrapRoot 'scrap/Scrap.icon'
$scrapOutput = Join-Path $PSScriptRoot 'Scrap/Assets'
New-Item -ItemType Directory -Force $scrapOutput | Out-Null
$scrapConfig = Get-Content (Join-Path $scrapSource 'icon.json') -Raw | ConvertFrom-Json
$scrapLayer = $scrapConfig.groups[0].layers[0]
$scrapSvg = Get-Content (Join-Path $scrapSource ('Assets/' + $scrapLayer.'image-name')) -Raw
$scrapBytes = [Convert]::FromBase64String([regex]::Match($scrapSvg, 'data:image/png;base64,([^"\s]+)').Groups[1].Value)
$scrapInput = [IO.MemoryStream]::new($scrapBytes, $false)
$scrapNote = [Drawing.Image]::FromStream($scrapInput)
function Convert-P3Color([string]$value) {
    $channels = $value.Split(':')[1].Split(',') | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) }
    $linear = $channels[0..2] | ForEach-Object { if ($_ -le 0.04045) { $_ / 12.92 } else { [Math]::Pow(($_ + 0.055) / 1.055, 2.4) } }
    $rgb = @((1.224745 * $linear[0] - 0.224904 * $linear[1]), (-0.042058 * $linear[0] + 1.042081 * $linear[1]), (-0.019642 * $linear[0] - 0.078655 * $linear[1] + 1.098537 * $linear[2]))
    $encoded = $rgb | ForEach-Object { $v = [Math]::Min([Math]::Max([double]$_, 0.0), 1.0); if ($v -le 0.0031308) { [int][Math]::Round(255 * 12.92 * $v) } else { [int][Math]::Round(255 * (1.055 * [Math]::Pow($v, 1 / 2.4) - 0.055)) } }
    return [Drawing.Color]::FromArgb(255, $encoded[0], $encoded[1], $encoded[2])
}
$scrapCanvas = [Drawing.Bitmap]::new(1024, 1024)
$scrapGraphics = [Drawing.Graphics]::FromImage($scrapCanvas)
$scrapGraphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$scrapGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$scrapShape = [Drawing.Drawing2D.GraphicsPath]::new()
foreach ($arc in @(@(0,0,180), @(624,0,270), @(624,624,0), @(0,624,90))) { $scrapShape.AddArc($arc[0], $arc[1], 400, 400, $arc[2], 90) }
$scrapShape.CloseFigure()
$scrapColors = $scrapConfig.fill.'linear-gradient'
$scrapGradient = [Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Point]::new(512,0), [Drawing.Point]::new(512,1024), (Convert-P3Color $scrapColors[0]), (Convert-P3Color $scrapColors[1]))
$scrapBlend = [Drawing.Drawing2D.ColorBlend]::new(3)
$scrapBlend.Colors = @((Convert-P3Color $scrapColors[0]), (Convert-P3Color $scrapColors[1]), (Convert-P3Color $scrapColors[1]))
$scrapBlend.Positions = [single[]]@(0, 0.7, 1)
$scrapGradient.InterpolationColors = $scrapBlend
$scrapGraphics.FillPath($scrapGradient, $scrapShape)
$scrapTranslation = $scrapLayer.position.'translation-in-points'
$scrapWidth = 194 * $scrapLayer.position.scale
$scrapHeight = 744 * $scrapLayer.position.scale
$scrapRect = [Drawing.RectangleF]::new((1024-$scrapWidth)/2+$scrapTranslation[0], (1024-$scrapHeight)/2+$scrapTranslation[1], $scrapWidth, $scrapHeight)
$scrapGraphics.DrawImage($scrapNote, $scrapRect, [Drawing.RectangleF]::new(1,1,194,744), [Drawing.GraphicsUnit]::Pixel)
$scrapCanvas.Save((Join-Path $scrapOutput 'Scrap.png'), [Drawing.Imaging.ImageFormat]::Png)
$scrapSizes = @(16,20,24,32,40,48,64,128,256)
function Write-ScrapIcon([Drawing.Bitmap]$canvas, [string]$name) {
    $frames = [Collections.Generic.List[byte[]]]::new()
    foreach ($size in $scrapSizes) {
        $frame = [Drawing.Bitmap]::new($size, $size)
        $g = [Drawing.Graphics]::FromImage($frame)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($canvas, 0, 0, $size, $size)
        $stream = [IO.MemoryStream]::new()
        $frame.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        $frames.Add($stream.ToArray())
        $stream.Dispose(); $g.Dispose(); $frame.Dispose()
    }
    $file = [IO.File]::Create((Join-Path $scrapOutput $name))
    $writer = [IO.BinaryWriter]::new($file)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$scrapSizes.Count)
    $offset = 6 + 16 * $scrapSizes.Count
    for ($i=0; $i -lt $scrapSizes.Count; $i++) {
        $dimension = if ($scrapSizes[$i] -eq 256) { 0 } else { $scrapSizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($frame in $frames) { $writer.Write($frame) }
    $writer.Dispose()
}
Write-ScrapIcon $scrapCanvas 'Scrap.ico'
# The tray shows this greyed-out version while scrap isn't scrobbling.
$scrapIdle = [Drawing.Bitmap]::new(1024, 1024)
$scrapIdleGraphics = [Drawing.Graphics]::FromImage($scrapIdle)
$scrapGrey = [Drawing.Imaging.ColorMatrix]::new([single[][]]@(
    [single[]]@(0.3, 0.3, 0.3, 0, 0), [single[]]@(0.59, 0.59, 0.59, 0, 0), [single[]]@(0.11, 0.11, 0.11, 0, 0),
    [single[]]@(0, 0, 0, 0.75, 0), [single[]]@(0, 0, 0, 0, 1)))
$scrapAttributes = [Drawing.Imaging.ImageAttributes]::new()
$scrapAttributes.SetColorMatrix($scrapGrey)
$scrapIdleGraphics.DrawImage($scrapCanvas, [Drawing.Rectangle]::new(0, 0, 1024, 1024), 0, 0, 1024, 1024, [Drawing.GraphicsUnit]::Pixel, $scrapAttributes)
Write-ScrapIcon $scrapIdle 'ScrapIdle.ico'
$scrapAttributes.Dispose(); $scrapIdleGraphics.Dispose(); $scrapIdle.Dispose()
$scrapGraphics.Dispose(); $scrapCanvas.Dispose(); $scrapShape.Dispose(); $scrapGradient.Dispose(); $scrapNote.Dispose(); $scrapInput.Dispose()
Write-Output 'Created Scrap.ico and ScrapIdle.ico (16–256 px) and Scrap.png from the macOS assets.'
