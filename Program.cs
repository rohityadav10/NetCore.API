var builder = WebApplication.CreateBuilder(args);

// Add services to the container.

builder.Services.AddControllers();
// Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

// Liveness endpoint for deployment smoke tests (IIS) and Container Apps probes.
// Add dependency checks here (e.g. AddSqlServer) once the API has a database.
builder.Services.AddHealthChecks();

// Browser origins allowed to call this API — the Angular SPA's URL in each environment.
// Set per environment as Cors:AllowedOrigins:0..n (env var Cors__AllowedOrigins__0);
// none configured means no CORS policy, the same as before this setting existed.
var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
if (allowedOrigins.Length > 0)
{
    builder.Services.AddCors(options => options.AddDefaultPolicy(policy =>
        policy.WithOrigins(allowedOrigins).AllowAnyHeader().WithMethods("GET")));
}

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

// Only redirect to HTTPS if HTTPS port is configured
if (app.Configuration["HTTPS_PORT"] != null)
{
    app.UseHttpsRedirection();
}

if (allowedOrigins.Length > 0)
{
    app.UseCors();
}

app.UseAuthorization();

app.MapControllers();
app.MapHealthChecks("/health");

app.Run();

// Make the implicit Program class accessible to integration tests
public partial class Program { }
