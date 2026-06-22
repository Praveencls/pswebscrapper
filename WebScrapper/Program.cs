using WebScrapper.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.

builder.Services.AddControllers();
builder.Services.AddScoped<IWebMetadataService, PowerShellWebMetadataService>();
builder.Services.AddHttpClient<IAllHomesService, AllHomesService>(client =>
{
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (compatible; WebScrapper/1.0)");
    client.DefaultRequestHeaders.Accept.ParseAdd("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8");
});
builder.Services.AddHttpClient<IHomeDetailsService, HomeDetailsService>(client =>
{
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (compatible; WebScrapper/1.0)");
    client.DefaultRequestHeaders.Accept.ParseAdd("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8");
});
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();

app.UseAuthorization();

app.MapControllers();

app.Run();
