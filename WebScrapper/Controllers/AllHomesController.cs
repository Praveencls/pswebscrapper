using Microsoft.AspNetCore.Mvc;
using WebScrapper.Services;

namespace WebScrapper.Controllers;

[ApiController]
[Route("api/allHomes")]
public sealed class AllHomesController(IAllHomesService allHomesService) : ControllerBase
{
    /// <summary>Returns every child element inside the div identified by divId.</summary>
    [HttpGet]
    public async Task<IActionResult> Get(
        [FromQuery] string url,
        [FromQuery] string divId,
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

        if (string.IsNullOrWhiteSpace(divId))
        {
            return BadRequest(new { error = "The divId query parameter is required." });
        }

        try
        {
            var elements = await allHomesService.GetElementsAsync(
                parsedUrl,
                divId.Trim(),
                cancellationToken);

            if (elements is null)
            {
                return NotFound(new { error = $"A div with id '{divId.Trim()}' was not found." });
            }

            return Ok(elements);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new StatusCodeResult(499);
        }
        catch (Exception exception)
        {
            return Problem(
                title: "Unable to crawl the requested page",
                detail: exception.Message,
                statusCode: StatusCodes.Status502BadGateway);
        }
    }

}
