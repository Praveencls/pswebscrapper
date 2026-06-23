using WebScrapper.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.

builder.Services.AddControllers();
builder.Services.AddSingleton<IPowerShellJsonRunner, PowerShellJsonRunner>();
builder.Services.AddScoped<IWebMetadataService, PowerShellWebMetadataService>();
builder.Services.AddScoped<IAllHomesService, AllHomesService>();
builder.Services.AddScoped<IHomeDetailsService, HomeDetailsService>();
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
