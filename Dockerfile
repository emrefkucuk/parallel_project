FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src/ src/
RUN mvn -q clean package -DskipTests

FROM eclipse-temurin:17-jre
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    x11vnc \
    python3 \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/novnc/noVNC.git /opt/noVNC

COPY --from=build /app/target/parallel-malware-scanner.jar /app/

COPY src/main/resources/signatures /app/src/main/resources/signatures

COPY scripts/docker-entry.sh /app/docker-entry.sh
RUN sed -i 's/\r$//' /app/docker-entry.sh && chmod +x /app/docker-entry.sh

EXPOSE 8080

ENTRYPOINT ["/app/docker-entry.sh"]
