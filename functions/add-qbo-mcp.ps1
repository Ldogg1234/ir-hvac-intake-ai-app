$configPath = "$env:APPDATA\Gemini\antigravity\mcp_config.json"

if (-Not (Test-Path $configPath)) {
    Write-Error "Config file not found at $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Build the new server entry
$qboServer = @{
    command = "npx"
    args    = @("-y", "@qboapi/qbo-mcp-server@latest")
}

# Ensure mcpServers property exists
if (-Not $config.mcpServers) {
    $config | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
}

# Add or overwrite the qbo-mcp-server entry
if ($config.mcpServers.PSObject.Properties["qbo-mcp-server"]) {
    Write-Host "qbo-mcp-server already exists — overwriting."
    $config.mcpServers."qbo-mcp-server" = [PSCustomObject]$qboServer
} else {
    $config.mcpServers | Add-Member -NotePropertyName "qbo-mcp-server" -NotePropertyValue ([PSCustomObject]$qboServer)
}

$config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

Write-Host "QuickBooks MCP server added to $configPath"
