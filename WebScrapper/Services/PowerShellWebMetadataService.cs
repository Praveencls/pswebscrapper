using System.Text.Json;

namespace WebScrapper.Services;

public sealed class PowerShellWebMetadataService(IPowerShellJsonRunner runner) : IWebMetadataService
{
    public Task<JsonElement> GetMetadataAsync(Uri url, CancellationToken cancellationToken) =>
        runner.RunAsync(
            "Get-WebMetadata.ps1",
            new Dictionary<string, string?>
            {
                ["Url"] = url.AbsoluteUri,
                ["AsJson"] = null
            },
            standardInput: null,
            cancellationToken);
}
