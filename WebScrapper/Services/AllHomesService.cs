using System.Text.Json;

namespace WebScrapper.Services;

public sealed class AllHomesService(IPowerShellJsonRunner runner) : IAllHomesService
{
    public async Task<IReadOnlyList<IReadOnlyDictionary<string, string?>>?> GetElementsAsync(
        Uri url,
        string divId,
        CancellationToken cancellationToken)
    {
        var result = await runner.RunAsync(
            "Get-AllHomes.ps1",
            new Dictionary<string, string?>
            {
                ["Url"] = url.AbsoluteUri,
                ["DivId"] = divId
            },
            standardInput: null,
            cancellationToken);

        return result.ValueKind == JsonValueKind.Null
            ? null
            : JsonSerializer.Deserialize<IReadOnlyList<IReadOnlyDictionary<string, string?>>>(
                result.GetRawText());
    }
}
