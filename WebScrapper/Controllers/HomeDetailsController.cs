using Microsoft.AspNetCore.Mvc;
using WebScrapper.Models;
using WebScrapper.Services;

namespace WebScrapper.Controllers;

[ApiController]
[Route("api/homeDetails")]
public sealed class HomeDetailsController(IHomeDetailsService homeDetailsService) : ControllerBase
{
    private const int MaximumHomesPerRequest = 100;

    /// <summary>Crawls each homeLink and returns detail-page properties.</summary>
    [HttpPost]
    public async Task<IActionResult> Post(
        [FromBody] IReadOnlyList<HomeLinkRequest> homes,
        CancellationToken cancellationToken)
    {
        if (homes.Count == 0)
        {
            return BadRequest(new { error = "The request body must contain at least one home." });
        }

        if (homes.Count > MaximumHomesPerRequest)
        {
            return BadRequest(new
            {
                error = $"A maximum of {MaximumHomesPerRequest} homes is allowed per request."
            });
        }

        var homeLinks = new List<Uri>(homes.Count);
        for (var index = 0; index < homes.Count; index++)
        {
            var value = homes[index].HomeLink;
            if (!Uri.TryCreate(value, UriKind.Absolute, out var homeLink) ||
                (homeLink.Scheme != Uri.UriSchemeHttp && homeLink.Scheme != Uri.UriSchemeHttps))
            {
                return BadRequest(new
                {
                    error = $"Item {index} must contain a valid absolute HTTP or HTTPS homeLink."
                });
            }

            homeLinks.Add(homeLink);
        }

        try
        {
            var details = await homeDetailsService.GetDetailsAsync(homeLinks, cancellationToken);
            return Ok(details);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new StatusCodeResult(499);
        }
        catch (Exception exception)
        {
            return Problem(
                title: "Unable to crawl one or more home detail pages",
                detail: exception.Message,
                statusCode: StatusCodes.Status502BadGateway);
        }
    }
}
