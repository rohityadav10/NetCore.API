using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using System.Net.Http.Json;
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
        Assert.Equal("1.2.0", json["version"]?.ToString());
    }
}
