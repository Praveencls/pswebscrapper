using System.Text.Json.Serialization;

namespace WebScrapper.Models;

public sealed record HtmlElementResult(
    [property: JsonPropertyName("tagName")] string TagName,
    [property: JsonPropertyName("attributes")] IReadOnlyDictionary<string, string> Attributes,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("innerHtml")] string InnerHtml,
    [property: JsonPropertyName("children")] IReadOnlyList<HtmlElementResult> Children);
