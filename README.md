# NetCore.API

A sample ASP.NET Core Web API application built with **.NET 8** and designed to demonstrate application development, automated testing, containerization, and CI/CD using GitHub Actions.

## Overview

This repository contains the backend REST API for the application.

The project demonstrates:

* ASP.NET Core Web API development
* REST API endpoints
* Automated unit testing
* Docker containerization
* GitHub Actions CI/CD
* Code quality and security checks
* Build and deployment automation

## Technology Stack

| Technology           | Purpose                       |
| -------------------- | ----------------------------- |
| .NET 8               | Backend application framework |
| ASP.NET Core Web API | REST API development          |
| C#                   | Programming language          |
| xUnit                | Unit testing                  |
| Docker               | Application containerization  |
| GitHub Actions       | CI/CD automation              |
| Swagger / OpenAPI    | API documentation             |

## Repository Structure

```text
NetCore.API/
│
├── .github/
│   └── workflows/
│       └── CI/CD workflow files
│
├── Controllers/
│   └── API controllers
│
├── Properties/
│   └── Application configuration
│
├── tests/
│   └── NetCore.API.Tests/
│       └── Automated tests
│
├── Dockerfile
├── NetCore.API.csproj
├── NetCore.API.sln
├── Program.cs
├── WeatherForecast.cs
├── appsettings.json
├── appsettings.Development.json
└── NetCore.API.http
```

## Running Locally

### Prerequisites

Install:

* .NET 8 SDK
* Git
* Docker (optional)

### Clone the Repository

```bash
git clone https://github.com/rohityadav10/NetCore.API.git
cd NetCore.API
```

### Restore Dependencies

```bash
dotnet restore
```

### Build the Application

```bash
dotnet build
```

### Run the Application

```bash
dotnet run
```

The API can then be accessed through the URL displayed by the application.

Swagger/OpenAPI can be used to explore and test the available API endpoints when enabled.

## Running Tests

The automated tests are located under:

```text
tests/NetCore.API.Tests/
```

Run the tests using:

```bash
dotnet test
```

For CI/CD, test execution is automated through GitHub Actions.

## Docker

The application includes a Dockerfile for containerized execution.

### Build the Docker Image

```bash
docker build -t netcore-api .
```

### Run the Container

```bash
docker run -d -p 8080:8080 --name netcore-api netcore-api
```

The application can then be accessed through the mapped port.

## CI/CD

The repository uses **GitHub Actions** for CI/CD automation.

The pipeline is designed to automate activities such as:

1. Source code checkout
2. .NET dependency restoration
3. Application build
4. Automated testing
5. Code quality/security validation
6. Docker image build
7. Deployment-related activities

Workflow files are maintained under:

```text
.github/workflows/
```

## Branch Strategy

The repository follows a feature-based development approach.

```text
feature/*
    ↓
Build / Test / Security Validation
    ↓
Pull Request
    ↓
main / release
    ↓
Deployment Pipeline
```

Feature branches are validated before merging, while deployment activities are associated with the main/release delivery flow.

## Security

The CI/CD process is designed to prevent insecure code and dependencies from progressing through the delivery pipeline.

Security considerations include:

* Avoiding hardcoded secrets
* Dependency vulnerability scanning
* Static code/security analysis
* Secure handling of deployment credentials
* Container security validation

Sensitive values should be stored using secure repository/environment secrets rather than committed to source control.

## Configuration

Application configuration is maintained through the standard ASP.NET Core configuration mechanism.

Environment-specific or sensitive configuration values should be supplied through environment variables, GitHub Actions secrets, or the appropriate deployment environment configuration.

No credentials or sensitive secrets should be committed to the repository.

## Container Deployment

The application is container-ready and can be deployed to container platforms such as Azure Container Apps.

The container deployment approach provides:

* Repeatable deployments
* Environment isolation
* Application portability
* Health-check based validation
* Easy rollback to a previously deployed image

## Backend and Frontend

This API serves as the backend component of the overall application.

The corresponding Angular frontend is maintained separately in the:

**Angular.web** repository.

## Project Purpose

This project is primarily intended as a DevOps/CI-CD exercise demonstrating how a .NET application can be integrated into an automated software delivery lifecycle.

The focus is on:

* Build automation
* Automated testing
* Security validation
* Containerization
* CI/CD
* Deployment automation
* Environment-based delivery

## License

This project is provided for demonstration and learning purposes.
