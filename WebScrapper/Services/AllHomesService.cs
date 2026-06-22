using System.Net;
using HtmlAgilityPack;
using WebScrapper.Constants;

namespace WebScrapper.Services;

public sealed class AllHomesService(HttpClient httpClient) : IAllHomesService
{
    public async Task<IReadOnlyList<IReadOnlyDictionary<string, string?>>?> GetElementsAsync(
        Uri url,
        string divId,
        CancellationToken cancellationToken)
    {
        using var response = await httpClient.GetAsync(
            url,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);

        response.EnsureSuccessStatusCode();

        var mediaType = response.Content.Headers.ContentType?.MediaType;
        if (mediaType is not null &&
            !mediaType.Equals("text/html", StringComparison.OrdinalIgnoreCase) &&
            !mediaType.Equals("application/xhtml+xml", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Unsupported content type '{mediaType}'. Expected an HTML page.");
        }

        var html = await response.Content.ReadAsStringAsync(cancellationToken);
        var document = new HtmlDocument();
        document.LoadHtml(html);

        var container = document.GetElementbyId(divId);
        if (container is null ||
            !container.Name.Equals("div", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return container.ChildNodes
            .Where(node => node.NodeType == HtmlNodeType.Element)
            .Select(node => ExtractProperties(node, url))
            .ToArray();
    }

    private static IReadOnlyDictionary<string, string?> ExtractProperties(
        HtmlNode homeNode,
        Uri pageUrl)
    {
        var result = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);

        foreach (var property in AllHomesProperties.AttributeSelectors)
        {
            var value = homeNode.Attributes[property.Value]?.Value;
            var decodedValue = value is null
                ? null
                : WebUtility.HtmlDecode(value).Trim();

            if (property.Key.Equals(AllHomesProperties.HomeLink, StringComparison.OrdinalIgnoreCase) &&
                decodedValue is not null &&
                Uri.TryCreate(pageUrl, decodedValue, out var absoluteLink))
            {
                decodedValue = absoluteLink.AbsoluteUri;
            }

            result[property.Key] = decodedValue;
        }

        foreach (var property in AllHomesProperties.ClassAttributeSelectors)
        {
            var selector = property.Value;
            var propertyNode = homeNode
                .DescendantsAndSelf()
                .FirstOrDefault(node => HasClass(node, selector.ClassName));

            var value = propertyNode?.Attributes[selector.AttributeName]?.Value;

            if (value is null &&
                propertyNode is not null &&
                selector.FallbackTagName is not null &&
                selector.FallbackAttributeName is not null)
            {
                value = propertyNode
                    .Descendants(selector.FallbackTagName)
                    .FirstOrDefault()?
                    .Attributes[selector.FallbackAttributeName]?
                    .Value;
            }

            result[property.Key] = value is null
                ? null
                : WebUtility.HtmlDecode(value).Trim();
        }

        foreach (var property in AllHomesProperties.ClassSelectors)
        {
            var propertyNode = homeNode
                .DescendantsAndSelf()
                .FirstOrDefault(node => HasClass(node, property.Value));

            result[property.Key] = propertyNode is null
                ? null
                : NormalizeText(propertyNode.InnerText);
        }

        var badgeNode = AllHomesProperties.BadgeClassPaths
            .Select(classPath => FindByClassPath(homeNode, classPath))
            .FirstOrDefault(node => node is not null);

        result[AllHomesProperties.Badge] = badgeNode is null
            ? null
            : NormalizeText(badgeNode.InnerText);

        return result;
    }

    private static HtmlNode? FindByClassPath(
        HtmlNode root,
        IReadOnlyList<string> classPath)
    {
        HtmlNode? current = root;

        foreach (var className in classPath)
        {
            current = current
                .DescendantsAndSelf()
                .FirstOrDefault(node => HasClass(node, className));

            if (current is null)
            {
                return null;
            }
        }

        return current;
    }

    private static bool HasClass(HtmlNode node, string className)
    {
        var classes = node.GetAttributeValue("class", string.Empty)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

        return classes.Contains(className, StringComparer.OrdinalIgnoreCase);
    }

    private static string NormalizeText(string value)
    {
        var decoded = WebUtility.HtmlDecode(value);
        return string.Join(' ', decoded.Split(
            (char[]?)null,
            StringSplitOptions.RemoveEmptyEntries));
    }
}
