using System.Net;
using HtmlAgilityPack;
using WebScrapper.Constants;

namespace WebScrapper.Services;

public sealed class HomeDetailsService(HttpClient httpClient) : IHomeDetailsService
{
    private const int MaximumConcurrency = 5;

    public async Task<IReadOnlyList<IReadOnlyDictionary<string, string?>>> GetDetailsAsync(
        IReadOnlyList<Uri> homeLinks,
        CancellationToken cancellationToken)
    {
        using var concurrency = new SemaphoreSlim(MaximumConcurrency);

        var tasks = homeLinks.Select(async homeLink =>
        {
            await concurrency.WaitAsync(cancellationToken);
            try
            {
                return await GetDetailAsync(homeLink, cancellationToken);
            }
            finally
            {
                concurrency.Release();
            }
        });

        return await Task.WhenAll(tasks);
    }

    private async Task<IReadOnlyDictionary<string, string?>> GetDetailAsync(
        Uri homeLink,
        CancellationToken cancellationToken)
    {
        using var response = await httpClient.GetAsync(
            homeLink,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);

        response.EnsureSuccessStatusCode();

        var html = await response.Content.ReadAsStringAsync(cancellationToken);
        var document = new HtmlDocument();
        document.LoadHtml(html);

        var builderContainer = document.DocumentNode
            .DescendantsAndSelf()
            .FirstOrDefault(node => HasClass(
                node,
                HomeDetailProperties.BuilderContainerClass));

        var builderMeta = builderContainer?
            .Descendants("meta")
            .FirstOrDefault(node => node
                .GetAttributeValue("itemprop", string.Empty)
                .Equals(HomeDetailProperties.BuilderMetaItemProp, StringComparison.OrdinalIgnoreCase));

        var builderName = builderMeta?.Attributes["content"]?.Value;

        return new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
        {
            [HomeDetailProperties.HomeLink] = homeLink.AbsoluteUri,
            [HomeDetailProperties.BuilderName] = builderName is null
                ? null
                : WebUtility.HtmlDecode(builderName).Trim()
        };
    }

    private static bool HasClass(HtmlNode node, string className)
    {
        var classes = node.GetAttributeValue("class", string.Empty)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

        return classes.Contains(className, StringComparer.OrdinalIgnoreCase);
    }
}
