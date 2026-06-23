using System.Text.Json;

namespace WebScrapper.Services;

public sealed class HomeDetailsService(IPowerShellJsonRunner runner) : IHomeDetailsService
{
    public async Task<IReadOnlyList<IReadOnlyDictionary<string, string?>>> GetDetailsAsync(
        IReadOnlyList<Uri> homeLinks,
        CancellationToken cancellationToken)
    {
        var input = JsonSerializer.Serialize(
            homeLinks.Select(link => new { homeLink = link.AbsoluteUri }));

        var result = await runner.RunAsync(
            "Get-HomeDetails.ps1",
            new Dictionary<string, string?>
            {
                ["ReadFromStandardInput"] = null,
                ["ScrapeDetails"] = "1"
            },
            input,
            cancellationToken);

        return JsonSerializer.Deserialize<IReadOnlyList<IReadOnlyDictionary<string, string?>>>(
                   result.GetRawText())
               ?? [];
    }
}
