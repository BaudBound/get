param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$Root
)

$ErrorActionPreference = "Stop"
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            while ($reader.ReadLine()) {}

            $requestPath = ($requestLine -split " ")[1].TrimStart("/")
            $filePath = Join-Path $Root ([Uri]::UnescapeDataString($requestPath))
            if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                $body = [IO.File]::ReadAllBytes($filePath)
                $status = "200 OK"
                $contentType = if ($filePath.EndsWith(".json")) {
                    "application/json; charset=utf-8"
                } else {
                    "application/octet-stream"
                }
            } else {
                $body = [Text.Encoding]::UTF8.GetBytes("not found")
                $status = "404 Not Found"
                $contentType = "text/plain"
            }
            $header = [Text.Encoding]::ASCII.GetBytes(
                "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
            )
            $stream.Write($header, 0, $header.Length)
            $stream.Write($body, 0, $body.Length)
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
