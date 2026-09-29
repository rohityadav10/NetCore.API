using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json.Nodes;
using Xunit;

namespace NetCore.API.Tests;

public class AppStatusControllerTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public AppStatusControllerTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task GetStatus_ReturnsOkWithHealthyStatus()
    {
        // Act
        var response = await _client.GetAsync("/api/AppStatus");

        // Assert
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var json = await response.Content.ReadFromJsonAsync<JsonObject>();
        Assert.NotNull(json);
        Assert.Equal("Healthy", json["status"]?.ToString());
        Assert.Equal("NetCore.API", json["service"]?.ToString());
    }

    [Fact]
    public async Task GetStatus_ReportsTheStampedBuildVersion()
    {
        // The pipeline stamps InformationalVersion with its build number; locally it is <Version>.
        var expected = typeof(Program).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion;

        var json = await _client.GetFromJsonAsync<JsonObject>("/api/AppStatus");

        Assert.NotNull(json);
        Assert.False(string.IsNullOrWhiteSpace(expected));
        Assert.Equal(expected, json["version"]?.ToString());
    }
}
