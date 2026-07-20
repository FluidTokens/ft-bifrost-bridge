# Build binocular from a sibling checkout (compose sets the build context to
# BINOCULAR_SRC). binocular's own root Dockerfile is stale (its build image
# lacks sbt and it copies a jar name that build.sbt doesn't produce), so the
# working recipe lives here until fixed upstream.
# VERIFY: keep the sbt/scala tag aligned with binocular's build.sbt
# (scala 3.3.7, sbt-assembly, assemblyJarName := "binocular.jar").
FROM sbtscala/scala-sbt:eclipse-temurin-21.0.5_11_1.10.7_3.3.4 AS build
WORKDIR /src
COPY . .
RUN sbt assembly

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/scala-3.3.7/binocular.jar /app/binocular.jar
ENTRYPOINT ["java", "-jar", "/app/binocular.jar"]
