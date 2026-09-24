using Microsoft.AspNetCore.Mvc;

namespace NetCore.API.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AppStatusController : ControllerBase
{
    private readonly IWebHostEnvironment _environment;

    public AppStatusController(IWebHostEnvironment environment)
    {
        _environment = environment;
    }

    [HttpGet]
    public IActionResult GetStatus()
    {
        return Ok(new
        {
            Status = "Healthy",
            Service = "NetCore.API",
            Version = "1.2.0",
            Environment = _environment.EnvironmentName,
            ServerTimeUtc = DateTime.UtcNow
        });
    }
}
