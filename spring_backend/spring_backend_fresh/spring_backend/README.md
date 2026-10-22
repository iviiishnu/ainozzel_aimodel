# Spring Backend

API gateway on **port 8000**. It receives images from the tablet app and forwards them to the Python ML server (`:5010`).

## Requirements

- JDK **17**
- Maven is not needed; the wrapper (`mvnw` / `mvnw.cmd`) is included
- Dependencies are in [`pom.xml`](pom.xml): Spring Boot 3.5.5 (web, actuator)

## Run

```powershell
.\mvnw.cmd spring-boot:run          # Windows
./mvnw spring-boot:run              # Linux/macOS
```

Production jar:
```powershell
.\mvnw.cmd -DskipTests package
java -jar target\spring_backend-0.0.1-SNAPSHOT.jar
```

## Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `SERVER_PORT` | `8000` | HTTP port |
| `AI_SERVICE_URL` | `http://127.0.0.1:5010` | Python ML server |
| `AI_SERVICE_READ_TIMEOUT` | `60s` | ML request timeout |
| `MAX_UPLOAD_SIZE` | `10MB` | Max image size |

## Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/crop/analyze` | Multipart `file` → disease, confidence, damage % |
| `GET` | `/api/crop/health` | Backend + ML server health |
| `GET` | `/api/crop/test` | Simple liveness check |

The tablet must be able to reach `<pc-ip>:8000`, so allow the port in the firewall.
