# ──────────────────────────────────────────────
# Stage 1: Build with .NET SDK
# ──────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy solution and project files first (layer caching)
COPY NetCore.API.sln .
COPY NetCore.API.csproj .
COPY tests/NetCore.API.Tests/NetCore.API.Tests.csproj tests/NetCore.API.Tests/

# Restore dependencies (cached unless .csproj changes)
RUN dotnet restore NetCore.API.sln

# Copy remaining source code
COPY . .

# Build in Release mode
RUN dotnet build NetCore.API.sln --configuration Release --no-restore

# Publish the API project
RUN dotnet publish NetCore.API.csproj --configuration Release --no-build --output /app/publish

# ──────────────────────────────────────────────
# Stage 2: Runtime image (no SDK — smaller, more secure)
# ──────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

# Create a non-root user for security
RUN adduser --disabled-password --gecos "" appuser

# Copy published output from build stage
COPY --from=build /app/publish .

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/WeatherForecast || exit 1

ENTRYPOINT ["dotnet", "NetCore.API.dll"]
