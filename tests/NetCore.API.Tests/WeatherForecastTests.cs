using NetCore.API;

namespace NetCore.API.Tests;

public class WeatherForecastTests
{
    [Fact]
    public void TemperatureF_ShouldConvertCorrectly()
    {
        // Arrange
        var forecast = new WeatherForecast
        {
            Date = DateOnly.FromDateTime(DateTime.Now),
            TemperatureC = 0,
            Summary = "Freezing"
        };

        // Act
        var fahrenheit = forecast.TemperatureF;

        // Assert
        Assert.Equal(32, fahrenheit);
    }

    [Fact]
    public void TemperatureF_At100C_ShouldReturn212F()
    {
        var forecast = new WeatherForecast
        {
            Date = DateOnly.FromDateTime(DateTime.Now),
            TemperatureC = 100,
            Summary = "Scorching"
        };

        Assert.True(forecast.TemperatureF > 200);
    }

    [Fact]
    public void WeatherForecast_Properties_ShouldBeSettable()
    {
        var date = DateOnly.FromDateTime(DateTime.Now);
        var forecast = new WeatherForecast
        {
            Date = date,
            TemperatureC = 25,
            Summary = "Warm"
        };

        Assert.Equal(date, forecast.Date);
        Assert.Equal(25, forecast.TemperatureC);
        Assert.Equal("Warm", forecast.Summary);
    }

    [Fact]
    public void WeatherForecast_Summary_CanBeNull()
    {
        var forecast = new WeatherForecast
        {
            Date = DateOnly.FromDateTime(DateTime.Now),
            TemperatureC = 0
        };

        Assert.Null(forecast.Summary);
    }
}
