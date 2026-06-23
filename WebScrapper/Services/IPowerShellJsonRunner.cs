using System.Text.Json;

namespace WebScrapper.Services;

public interface IPowerShellJsonRunner
{
    Task<JsonElement> RunAsync(
        string scriptName,
        IReadOnlyDictionary<string, string?> arguments,
        string? standardInput,
        CancellationToken cancellationToken);
}
