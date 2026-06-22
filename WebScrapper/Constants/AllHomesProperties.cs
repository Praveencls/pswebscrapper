namespace WebScrapper.Constants;

public static class AllHomesProperties
{
    public const string HomeName = "homeName";
    public const string BuilderName = "builderName";
    public const string HomeAddress = "homeAddress";
    public const string HomeId = "homeId";
    public const string HomeLink = "homeLink";
    public const string ThumbnailImage = "thumbnailImage";
    public const string Badge = "badge";

    // The badge can be represented by either of these markup patterns.
    public static readonly IReadOnlyList<IReadOnlyList<string>> BadgeClassPaths =
    [
        ["featured"],
        ["banner", "nameDirect"]
    ];

    // Key: property name in the returned JSON. Value: attribute on the home card.
    public static readonly IReadOnlyDictionary<string, string> AttributeSelectors =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [HomeId] = "homeid",
            [HomeLink] = "homelink"
        };

    // Reads an attribute from an element selected by class, with an optional
    // descendant element/attribute fallback.
    public static readonly IReadOnlyDictionary<string, ClassAttributeSelector>
        ClassAttributeSelectors =
            new Dictionary<string, ClassAttributeSelector>(StringComparer.OrdinalIgnoreCase)
            {
                [ThumbnailImage] = new(
                    ClassName: "imageContainer",
                    AttributeName: "data-img",
                    FallbackTagName: "img",
                    FallbackAttributeName: "src")
            };

    // Key: property name in the returned JSON. Value: HTML class to read.
    public static readonly IReadOnlyDictionary<string, string> ClassSelectors =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [HomeName] = "homeName",
            [BuilderName] = "builderName",
            [HomeAddress] = "homeAddress"
        };
}

public sealed record ClassAttributeSelector(
    string ClassName,
    string AttributeName,
    string? FallbackTagName = null,
    string? FallbackAttributeName = null);
