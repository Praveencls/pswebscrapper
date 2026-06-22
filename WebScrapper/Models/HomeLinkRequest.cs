using System.Text.Json.Serialization;

namespace WebScrapper.Models;

public sealed record HomeLinkRequest(
    [property: JsonPropertyName("homeLink")] string? HomeLink);
