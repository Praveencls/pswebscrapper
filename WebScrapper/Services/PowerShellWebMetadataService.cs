using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;

namespace WebScrapper.Services;

public sealed class PowerShellWebMetadataService(
    IWebHostEnvironment environment,
    ILogger<PowerShellWebMetadataService> logger) : IWebMetadataService
{
    private readonly string _scriptPath = Path.GetFullPath(
        Path.Combine(environment.ContentRootPath, "..", "Get-WebMetadata.ps1"));

    public async Task<JsonElement> GetMetadataAsync(
        Uri url,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(_scriptPath))
        {
            throw new FileNotFoundException("The metadata PowerShell script was not found.", _scriptPath);
        }

        using var process = CreateProcess(url);

        try
        {
            process.Start();
        }
        catch (Win32Exception exception)
        {
            throw new InvalidOperationException(
                "PowerShell could not be started. Ensure pwsh or powershell.exe is installed.",
                exception);
        }

        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        var output = await outputTask;
        var error = await errorTask;

        if (process.ExitCode != 0)
        {
            logger.LogWarning(
                "Metadata script failed for {Url} with exit code {ExitCode}: {Error}",
                url,
                process.ExitCode,
                error);

            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(error)
                    ? "The metadata script failed."
                    : error.Trim());
        }

        try
        {
            using var document = JsonDocument.Parse(output);
            return document.RootElement.Clone();
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                "The metadata script returned invalid JSON.",
                exception);
        }
    }

    private Process CreateProcess(Uri url)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = OperatingSystem.IsWindows() ? "powershell.exe" : "pwsh",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        // ArgumentList passes every value verbatim. URL characters are never parsed by a shell.
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(_scriptPath);
        startInfo.ArgumentList.Add("-Url");
        startInfo.ArgumentList.Add(url.AbsoluteUri);
        startInfo.ArgumentList.Add("-AsJson");

        return new Process { StartInfo = startInfo };
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process exited between the HasExited check and Kill.
        }
    }
}
