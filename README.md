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
    cap_add:
      - SYS_NICE
      - DAC_READ_SEARCH
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

> [!NOTE]
> **Linux Capabilities:** Koha Apache uses `mpm_itk` to isolate Koha instances under dedicated UIDs/GIDs (`default-koha`). The capabilities `SYS_NICE` and `DAC_READ_SEARCH` are required so Apache can perform user/group transitions within the container.

---

## Dienstleister-Zugang (Restricted Vendor SSH Access)

Wenn ein externer Koha-Dienstleister Konfigurationen, Migrationen oder Fehleranalysen durchführen soll, benötigt dieser **keinen** Root-Zugriff auf den Host-Server. Der Zugriff kann über einen isolierten Jump-User auf den Koha-Docker-Container beschränkt werden.

### Sicherheits-Architektur

1. **Kein Host-Zugriff:** Der Dienstleister erhält einen dedizierten Linux-Benutzer auf dem Host (`koha-support`).
2. **ForceCommand Wrapper:** In der SSH `authorized_keys` wird ein festes Wrapper-Skript `/usr/local/sbin/koha-container-shell` mit `ForceCommand` erzwungen (`no-port-forwarding,no-X11-forwarding,no-agent-forwarding`).
3. **Container-Isolation:** Nach SSH-Login wird die Session unmittelbar via `docker exec -it koha /bin/bash` in den laufenden Koha-Container geleitet. Der Dienstleister hat dort alle Koha-Werkzeuge und Root-Rechte *innerhalb des Containers*, sieht jedoch keine anderen Container, Netzwerke oder Host-Dateien.

### Konfiguration via Ansible (`roles/koha`)

In der Host- bzw. Gruppen-Variablendefinition des Ansible-Playbooks:

```yaml
koha_vendor_user_enabled: true
koha_vendor_username: "koha-support"
koha_vendor_ssh_keys:
  - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... dienstleister@koha-support"
```

### Befehle für den Dienstleister

| Befehl | Auswirkung |
| --- | --- |
| `ssh koha-support@<server-host>` | Öffnet eine interaktive Bash-Shell direkt im Koha-Container (`/bin/bash`). |
| `ssh koha-support@<server-host> restart` | Startet den Koha-Container neu (`docker restart koha`). |
| `ssh koha-support@<server-host> logs` | Verfolgt die aktuellen Container-Logs live (`docker logs -f --tail 200 koha`). |
| `ssh koha-support@<server-host> status` | Zeigt den aktuellen Container-Status an (`docker ps`). |

### Datei-Austausch (`/var/lib/koha/transfer`)

Für Daten-Importe (MARC21/PICA XML, CSV-Kataloge, SQL-Dumps oder Plugins) steht ein persistenter Austauschordner zur Verfügung:
* Im Container: `/var/lib/koha/transfer`
* Auf dem Host: `<docker_data_dir>/koha/koha_state/transfer` (mit Rechten `0777` für einfachen Datentransfer)

Dateien können vorab dort abgelegt oder vom Dienstleister via `curl`/`wget` direkt im Container heruntergeladen werden.

### Koha CLI-Werkzeuge im Container

Im Container stehen alle offiziellen Koha-Debian-Tools zur Verfügung (Standard-Instanzname ist `default`):

* **Koha Instanz-Shell:**
  ```bash
  koha-shell default
  ```
  Öffnet eine Shell als Instanz-Benutzer `default-koha` mit allen gesetzten Koha-Perl-Pfaden (`KOHA_CONF`, `PERL5LIB`).
* **Koha Datenbank-Client:**
  ```bash
  koha-mysql default
  ```
  Verbindet direkt mit der MariaDB-Datenbank der Koha-Instanz ohne manuelle Passworteingabe.
* **Plack / Starman verwalten:**
  ```bash
  koha-plack --restart default
  koha-plack --status default
  ```
* **Zebra MARC-Suchindex neu aufbauen:**
  ```bash
  koha-rebuild-zebra -v -f default
  ```
* **Elasticsearch-Suchindex neu aufbauen (falls aktiv):**
  ```bash
  koha-elasticsearch --rebuild -v default
  ```
* **Datenbankschema aktualisieren / Web-Installer CLI:**
  ```bash
  koha-upgrade-schema default
  ```
* **Sprachpakete verwalten:**
  ```bash
  koha-translate -l            # Installierte Sprachen auflisten
  koha-translate -i de-DE      # Deutsch installieren
  ```

---

## Credits

Based on the original foundation from [teogramm/koha-docker](https://github.com/teogramm/koha-docker) and [koha-community](https://gitlab.com/koha-community/docker/koha-docker).

