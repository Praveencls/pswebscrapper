using System.Text.Json;

namespace WebScrapper.Services;

public interface IWebMetadataService
{
    Task<JsonElement> GetMetadataAsync(Uri url, CancellationToken cancellationToken);
}
