#!/command/with-contenv bash

export KOHA_INSTANCE=default

export KOHA_INTRANET_PORT=8081
export KOHA_OPAC_PORT=8080
export USE_MEMCACHED=${USE_MEMCACHED:-yes}
export MEMCACHED_SERVERS=${MEMCACHED_SERVERS:-memcached:11211}
export MYSQL_SERVER=${MYSQL_SERVER:-db}
export DB_NAME=${DB_NAME:-koha_default}
export MYSQL_USER=${MYSQL_USER:-koha_default}
export MYSQL_PASSWORD=${MYSQL_PASSWORD:-$(pwgen -s 15 1)}
export ZEBRA_MARC_FORMAT=${ZEBRA_MARC_FORMAT:-marc21}
export KOHA_PLACK_NAME=${KOHA_PLACK_NAME:-koha}
export KOHA_ES_NAME=${KOHA_ES_NAME:-es}

# RabbitMQ settings (support both MB_* and RABBITMQ_* variables)
export MB_HOST=${MB_HOST:-${RABBITMQ_HOST:-rabbitmq}}
export MB_PORT=${MB_PORT:-61613}
export MB_USER=${MB_USER:-${RABBITMQ_USER:-guest}}
export MB_PASS=${MB_PASS:-${RABBITMQ_PASS:-guest}}

envsubst < /docker/templates/koha-sites.conf > /etc/koha/koha-sites.conf
printf "Listen 8080\nListen 8081\n" > /etc/apache2/ports.conf

# /etc/mysql/koha-common.cnf is used by a few koha scripts
rm -f /etc/mysql/koha-common.cnf && envsubst < /docker/templates/koha-common.cnf > /etc/mysql/koha-common.cnf
chmod 660 /etc/mysql/koha-common.cnf

# Use safe placeholder passwords for koha-create so its internal sed never breaks on /, &, \, <, >
echo -n "default:${MYSQL_USER}:placeholder_db_pass:${DB_NAME}:${MYSQL_SERVER}" > /etc/koha/passwd

source /usr/share/koha/bin/koha-functions.sh

MB_PARAMS="--mb-host ${MB_HOST} --mb-port ${MB_PORT} --mb-user ${MB_USER} --mb-pass placeholder_mb_pass"

# Configure the elasticsearch server
ES_PARAMS=""
if [[ "${USE_ELASTICSEARCH}" = "true" ]]
then
    ES_PARAMS="--elasticsearch-server ${ELASTICSEARCH_HOST}"
fi

if ! is_instance ${KOHA_INSTANCE} || [ ! -f "/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml" ]
then
    echo "Executing koha-create for instance ${KOHA_INSTANCE}"
    koha-create ${ES_PARAMS} ${MB_PARAMS} --use-db ${KOHA_INSTANCE} | true
fi

# Write actual credentials to /etc/koha/passwd
echo -n "default:${MYSQL_USER}:${MYSQL_PASSWORD}:${DB_NAME}:${MYSQL_SERVER}" > /etc/koha/passwd

echo "Ensuring directory structure for instance ${KOHA_INSTANCE}"
koha-create-dirs ${KOHA_INSTANCE}

# Ensure persistent encryption_key and up-to-date credentials in koha-conf.xml
CONF_FILE="/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
KEY_FILE="/var/lib/koha/${KOHA_INSTANCE}/.encryption_key"
if [ ! -s "${KEY_FILE}" ]; then
    pwgen -s 32 1 > "${KEY_FILE}"
    chmod 600 "${KEY_FILE}"
    chown ${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha "${KEY_FILE}"
fi
ENCRYPTION_KEY=$(cat "${KEY_FILE}")

if [ -f "${CONF_FILE}" ]; then
    sed -i "s|<encryption_key>__ENCRYPTION_KEY__</encryption_key>|<encryption_key>${ENCRYPTION_KEY}</encryption_key>|g" "${CONF_FILE}"
    xmlstarlet ed -L \
        -u "yazgfs/config/hostname" -v "${MYSQL_SERVER}" \
        -u "yazgfs/config/database" -v "${DB_NAME}" \
        -u "yazgfs/config/user" -v "${MYSQL_USER}" \
        -u "yazgfs/config/pass" -v "${MYSQL_PASSWORD}" \
        -u "yazgfs/config/memcached_servers" -v "${MEMCACHED_SERVERS}" \
        -u "yazgfs/config/message_broker/hostname" -v "${MB_HOST}" \
        -u "yazgfs/config/message_broker/port" -v "${MB_PORT}" \
        -u "yazgfs/config/message_broker/username" -v "${MB_USER}" \
        -u "yazgfs/config/message_broker/password" -v "${MB_PASS}" \
        "${CONF_FILE}" || true
fi

# Automatically upgrade database schema if Koha version changed
echo "Upgrading Koha database schema if needed..."
koha-upgrade-schema ${KOHA_INSTANCE} || true

# Patch Koha STOMP worker & BackgroundJob.pm so STOMP ERROR frames never cause a 100% CPU NACK ping-pong loop
BG_JOB_PM="/usr/share/koha/lib/Koha/BackgroundJob.pm"
if [ -f "${BG_JOB_PM}" ] && ! grep -q "STOMP auth failed" "${BG_JOB_PM}"; then
    perl -i -pe 's/\$stomp->connect\(\s*\$credentials\s*\);/my \$f = \$stomp->connect( \$credentials ); die "STOMP auth failed: " . (\$f ? \$f->body : "no frame") if !\$f || \$f->command ne "CONNECTED";/' "${BG_JOB_PM}"
fi

BG_WORKER_PL="/usr/share/koha/bin/workers/background_jobs_worker.pl"
if [ -f "${BG_WORKER_PL}" ] && ! grep -q "Ignoring non-MESSAGE STOMP frame" "${BG_WORKER_PL}"; then
    perl -0777 -i -pe 's/(if\s*\(\s*!defined\s+\$frame\s*\)\s*\{[^}]*\})/$1\n        if ( \$frame->command ne '\''MESSAGE'\'' ) {\n            Koha::Logger->get({ interface => '\''worker'\'' })->warn(sprintf "Ignoring non-MESSAGE STOMP frame (%s): %s", \$frame->command \/\/ '\'''\'', \$frame->body \/\/ '\'''\'');\n            sleep 5 if \$frame->command eq '\''ERROR'\'';\n            next;\n        }/s' "${BG_WORKER_PL}"
fi

# Prevent s6-supervise from spinning at high CPU if worker or indexer exits (e.g. before Web Installer initializes DB schema)
for svc in worker indexer; do
    if [ -d "/etc/s6-overlay/s6-rc.d/${svc}" ]; then
        printf '#!/bin/sh\nsleep 5\n' > "/etc/s6-overlay/s6-rc.d/${svc}/finish"
        chmod 755 "/etc/s6-overlay/s6-rc.d/${svc}/finish"
    fi
done

# Configure search daemon
if [ "${USE_ELASTICSEARCH}" = "true" ]
then
    koha-elasticsearch --rebuild -p $(grep -c ^processor /proc/cpuinfo) ${KOHA_INSTANCE} &
fi

for i in $(koha-translate -l)
do
    if [ "${KOHA_LANGS}" = "" ] || ! echo "${KOHA_LANGS}"|grep -q -w $i
    then
        echo "Removing language $i"
        koha-translate -r $i
    else
        echo "Checking language $i"
        koha-translate -c $i
    fi
done

if [ "${KOHA_LANGS}" != "" ]
then
    echo "Installing languages"
    LANGS=$(koha-translate -l)
    for i in $KOHA_LANGS
    do
        if ! echo "${LANGS}"|grep -q -w $i
        then
            echo "Installing language $i"
            koha-translate -i $i
        else
            echo "Language $i already present"
        fi
    done
fi

koha-plack --enable ${KOHA_INSTANCE}
a2enmod proxy headers setenvif
printf 'SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on\n' > /etc/apache2/conf-enabled/reverse-proxy-https.conf

# Prevent Plack from throwing permission errors
touch /var/log/koha/${KOHA_INSTANCE}/opac-error.log /var/log/koha/${KOHA_INSTANCE}/intranet-error.log
chown -R ${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha /var/log/koha/${KOHA_INSTANCE}/

service apache2 stop
koha-indexer --stop ${KOHA_INSTANCE}
koha-zebra --stop ${KOHA_INSTANCE}
koha-worker --stop ${KOHA_INSTANCE}
koha-email-enable ${KOHA_INSTANCE}

# Wait for RabbitMQ STOMP port before s6 launches background_jobs_worker.pl (prevents race condition on reboot/restart)
for _ in $(seq 1 30); do
    if bash -c "exec 3<>/dev/tcp/${MB_HOST}/${MB_PORT}" 2>/dev/null; then
        break
    fi
    sleep 1
done
