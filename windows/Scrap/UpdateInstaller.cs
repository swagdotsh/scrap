namespace Scrap;

public static class UpdateInstaller
{
    private static string Quote(string value) => value.Replace("'", "''");

    public static string Script(string install, string payload, string stage, string archive, int processId, bool background) => $$"""
        $ErrorActionPreference = 'Stop'
        $install = [IO.Path]::GetFullPath('{{Quote(install)}}').TrimEnd([IO.Path]::DirectorySeparatorChar)
        $payload = [IO.Path]::GetFullPath('{{Quote(payload)}}')
        $stage = [IO.Path]::GetFullPath('{{Quote(stage)}}').TrimEnd([IO.Path]::DirectorySeparatorChar)
        $archive = '{{Quote(archive)}}'
        $background = ${{(background ? "true" : "false")}}
        if ($install -eq [IO.Path]::GetPathRoot($install).TrimEnd([IO.Path]::DirectorySeparatorChar)) { throw 'Invalid installation directory' }
        if (-not $payload.StartsWith($stage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $payload -ne $stage) { throw 'Invalid payload directory' }
        if (-not (Test-Path -LiteralPath (Join-Path $payload 'Scrap.exe') -PathType Leaf)) { throw 'Missing Scrap.exe' }
        if (Get-Process -Id {{processId}} -ErrorAction SilentlyContinue) { Wait-Process -Id {{processId}} -Timeout 60 -ErrorAction Stop }
        $backup = $install + '.previous-' + [Guid]::NewGuid().ToString('N')
        function Start-Scrap {
            $exe = Join-Path $install 'Scrap.exe'
            if ($background) { Start-Process -FilePath $exe -ArgumentList '--background' }
            else { Start-Process -FilePath $exe }
        }
        Move-Item -LiteralPath $install -Destination $backup
        try {
            Copy-Item -LiteralPath $payload -Destination $install -Recurse
            $envFile = Join-Path $backup '.env'
            if (Test-Path -LiteralPath $envFile -PathType Leaf) { Copy-Item -LiteralPath $envFile -Destination (Join-Path $install '.env') }
            Start-Scrap
        }
        catch {
            if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
            Move-Item -LiteralPath $backup -Destination $install
            Start-Scrap
            throw
        }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        """;
}
