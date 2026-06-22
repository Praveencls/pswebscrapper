namespace WebScrapper.Services;

public interface IAllHomesService
{
    Task<IReadOnlyList<IReadOnlyDictionary<string, string?>>?> GetElementsAsync(
        Uri url,
        string divId,
        CancellationToken cancellationToken);
}
