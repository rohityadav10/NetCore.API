using Microsoft.AspNetCore.Mvc.Testing;
using System.Net;
using System.Net.Http.Json;
using Xunit;

namespace NetCore.API.Tests;

public class WeatherForecastControllerTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public WeatherForecastControllerTests(WebApplicationFactory<Program> factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task GetWeatherForecast_ReturnsOk()
    {
        // Act
        var response = await _client.GetAsync("/WeatherForecast");

        // Assert
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task GetWeatherForecast_ReturnsFiveForecasts()
    {
        // Act
        var forecasts = await _client.GetFromJsonAsync<WeatherForecast[]>("/WeatherForecast");

        // Assert
        Assert.NotNull(forecasts);
        Assert.Equal(5, forecasts.Length);
    }

    [Fact]
    public async Task GetWeatherForecast_ReturnsValidData()
    {
        // Act
        var forecasts = await _client.GetFromJsonAsync<WeatherForecast[]>("/WeatherForecast");

        // Assert
        Assert.NotNull(forecasts);
        Assert.All(forecasts, f =>
        {
            Assert.InRange(f.TemperatureC, -20, 55);
            Assert.NotNull(f.Summary);
            Assert.NotEmpty(f.Summary);
        });
    }

    [Fact]
    public async Task GetWeatherForecast_ReturnsJsonContentType()
    {
        // Act
        var response = await _client.GetAsync("/WeatherForecast");

        // Assert
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
    }
}
