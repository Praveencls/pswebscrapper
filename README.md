.\Get-SitemapUrls.ps1 -Sitemap "https://example.com/sitemap.xml" -OutputPath ".\urls.json"

.\Get-SitemapUrls.ps1 -Sitemap "https://freedsbakery.com/sitemap_products_1.xml?from=351396035&to=9726184816885" -OutputPath ".\urls.json"


.\Get-UrlsMetadata.ps1 -UrlsPath .\urls.json