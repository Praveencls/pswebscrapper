using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;

namespace WebScrapper.Services;

public sealed class PowerShellJsonRunner(
    IWebHostEnvironment environment,
    ILogger<PowerShellJsonRunner> logger) : IPowerShellJsonRunner
{
    public async Task<JsonElement> RunAsync(
        string scriptName,
        IReadOnlyDictionary<string, string?> arguments,
        string? standardInput,
        CancellationToken cancellationToken)
    {
        var scriptPath = Path.GetFullPath(
            Path.Combine(environment.ContentRootPath, "..", scriptName));

        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("The PowerShell script was not found.", scriptPath);
        }

        using var process = CreateProcess(scriptPath, arguments, standardInput is not null);

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
            if (standardInput is not null)
            {
                await process.StandardInput.WriteAsync(standardInput.AsMemory(), cancellationToken);
                process.StandardInput.Close();
            }

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
                "PowerShell script {ScriptName} failed with exit code {ExitCode}: {Error}",
                scriptName,
                process.ExitCode,
                error);

            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(error) ? "The PowerShell script failed." : error.Trim());
        }

        try
        {
            using var document = JsonDocument.Parse(output);
            return document.RootElement.Clone();
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                $"The PowerShell script '{scriptName}' returned invalid JSON.",
                exception);
        }
    }

    private static Process CreateProcess(
        string scriptPath,
        IReadOnlyDictionary<string, string?> arguments,
        bool redirectStandardInput)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = OperatingSystem.IsWindows() ? "powershell.exe" : "pwsh",
            RedirectStandardInput = redirectStandardInput,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        startInfo.Environment["WEB_SCRAPPER_APP_BASE_DIRECTORY"] = AppContext.BaseDirectory;

        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add($"-{argument.Key}");
            if (argument.Value is not null)
            {
                startInfo.ArgumentList.Add(argument.Value);
            }
        }

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
