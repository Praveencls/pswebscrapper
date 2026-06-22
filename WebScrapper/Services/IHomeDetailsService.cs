namespace WebScrapper.Services;

public interface IHomeDetailsService
{
    Task<IReadOnlyList<IReadOnlyDictionary<string, string?>>> GetDetailsAsync(
        IReadOnlyList<Uri> homeLinks,
        CancellationToken cancellationToken);
}
