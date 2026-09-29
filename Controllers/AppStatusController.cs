using System.Reflection;
using Microsoft.AspNetCore.Mvc;

namespace NetCore.API.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AppStatusController : ControllerBase
{
    // The CI build stamps InformationalVersion with the pipeline build number, so a
    // post-deploy smoke test can prove the new build is what is actually serving.
    // Local builds report <Version> from the csproj.
    private static readonly string AppVersion =
        typeof(AppStatusController).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown";

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
            Version = AppVersion,
            Environment = _environment.EnvironmentName,
            ServerTimeUtc = DateTime.UtcNow
        });
    }
}
