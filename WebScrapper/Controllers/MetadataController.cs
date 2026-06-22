using Microsoft.AspNetCore.Mvc;
using WebScrapper.Services;

namespace WebScrapper.Controllers;

[ApiController]
[Route("api/metadata")]
public sealed class MetadataController(IWebMetadataService metadataService) : ControllerBase
{
    /// <summary>Returns HTML metadata for an absolute HTTP or HTTPS URL.</summary>
    [HttpGet]
    public async Task<IActionResult> Get(
        [FromQuery] string url,
        CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsedUrl) ||
            (parsedUrl.Scheme != Uri.UriSchemeHttp && parsedUrl.Scheme != Uri.UriSchemeHttps))
        {
            return BadRequest(new
            {
                error = "The url query parameter must be a valid absolute HTTP or HTTPS URL."
            });
        }

        try
        {
            var metadata = await metadataService.GetMetadataAsync(parsedUrl, cancellationToken);
            return Ok(metadata);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new StatusCodeResult(499);
        }
        catch (Exception exception)
        {
            return Problem(
                title: "Unable to retrieve URL metadata",
                detail: exception.Message,
                statusCode: StatusCodes.Status502BadGateway);
        }
    }
}
