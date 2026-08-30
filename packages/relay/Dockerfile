# Builds the relay to a single static binary; the runtime image carries nothing
# but that binary and the Dart runtime's shared libraries.
FROM dart:3.9 AS build

WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/relay.dart -o bin/relay

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/relay /app/bin/relay

ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/relay"]
