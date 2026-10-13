# koha-docker

Modern, hardened Multi-Arch (`linux/amd64`, `linux/arm64`) Docker container for [Koha ILS](https://koha-community.org/) based on Debian Bookworm and `s6-overlay`.

## Available Tags & Versions

All images are published to the GitHub Container Registry (`ghcr.io/mystryx1337/koha`):

| Tag | Koha Release Track | Description | Multi-Arch |
| --- | --- | --- | --- |
| `25.05` | `25.05` | Koha 25.05 release series | `amd64`, `arm64` |
| `25.11` | `25.11` | Koha 25.11 release series | `amd64`, `arm64` |
| `stable` / `latest` | `stable` | Official current stable Koha release | `amd64`, `arm64` |
| `26.05` | `26.05` | Koha 26.05 development / preview | `amd64`, `arm64` |

## Key Improvements & Bugfixes

Compared to upstream `teogramm/koha`:
* **Multi-Arch Support:** Full native support for `linux/amd64` and `linux/arm64`.
* **STOMP ERROR Ping-Pong Loop Fix:** Patched `Net::Stomp` connect handling and non-`MESSAGE` frame processing in `background_jobs_worker.pl` to eliminate 100% CPU loops between Koha and RabbitMQ.
* **s6 Respawn Throttling:** Added `finish` scripts with delay for `worker` and `indexer` daemons to prevent high-CPU crash-looping before DB schema initialization.
* **Safe Credential Injection:** Replaced fragile `sed` password substitution with `xmlstarlet` to support passwords containing `/`, `&`, `\`, `<`, `>`.
* **Reverse Proxy HTTPS Support:** Automatic `SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on` for proper Apache CGI and Plack HTTPS detection behind Nginx / Traefik.
* **Fixed Typo:** Fixed `koha_conf.xml` filename check in `02-setup-koha.sh` to prevent accidental configuration rewrites on container restarts.

## Ports

* `8080`: Koha OPAC (Public Interface, served via Plack)
* `8081`: Koha Staff Client / Intranet (Administration, served via Plack)
* `2100`: Zebra Z39.50 server
* `6001`: Zebra SRU server

## Docker Compose Example

```yaml
services:
  koha:
    image: ghcr.io/mystryx1337/koha:25.05
    container_name: koha
    restart: always
    ports:
      - "8080:8080"
      - "8081:8081"
    environment:
      - MYSQL_SERVER=koha-db
      - DB_NAME=koha_default
      - MYSQL_USER=koha_default
      - MYSQL_PASSWORD=secret_db_pass
      - USE_MEMCACHED=yes
      - MEMCACHED_SERVERS=koha-memcached:11211
      - MB_HOST=koha-rabbitmq
      - MB_PORT=61613
      - MB_USER=koha_rabbit
      - MB_PASS=secret_rabbit_pass
      - KOHA_LANGS=de-DE
    volumes:
      - /opt/docker/data/koha/koha_state:/var/lib/koha
    depends_on:
      koha-db:
        condition: service_healthy
      koha-rabbitmq:
        condition: service_healthy
```

## Credits

Based on the original foundation from [teogramm/koha-docker](https://github.com/teogramm/koha-docker) and [koha-community](https://gitlab.com/koha-community/docker/koha-docker).
