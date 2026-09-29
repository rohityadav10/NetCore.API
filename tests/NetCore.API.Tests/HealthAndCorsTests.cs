using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using Xunit;

namespace NetCore.API.Tests;

public class HealthAndCorsTests : IClassFixture<WebApplicationFactory<Program>>
{
    private const string SpaOrigin = "http://spa.example.test";
    private readonly WebApplicationFactory<Program> _factory;

    public HealthAndCorsTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task Health_ReturnsHealthy()
    {
        var response = await _factory.CreateClient().GetAsync("/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Cors_ConfiguredOrigin_IsAllowed()
    {
        var client = _factory
            .WithWebHostBuilder(b => b.UseSetting("Cors:AllowedOrigins:0", SpaOrigin))
            .CreateClient();

        var request = new HttpRequestMessage(HttpMethod.Get, "/api/AppStatus");
        request.Headers.Add("Origin", SpaOrigin);
        var response = await client.SendAsync(request);

        Assert.True(response.Headers.TryGetValues("Access-Control-Allow-Origin", out var values));
        Assert.Equal(SpaOrigin, Assert.Single(values));
    }

    [Fact]
    public async Task Cors_NoOriginsConfigured_SendsNoCorsHeader()
    {
        var request = new HttpRequestMessage(HttpMethod.Get, "/api/AppStatus");
        request.Headers.Add("Origin", SpaOrigin);
        var response = await _factory.CreateClient().SendAsync(request);

        Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"));
    }
}
