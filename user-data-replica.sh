#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data-replica.log) 2>&1

PRIMARY_IP="${primary_ip}"
PG_VERSION=14
REPL_USER="replicator"
REPL_PASS="${repl_pass}"

echo "Installing PostgreSQL..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y postgresql-$PG_VERSION

########################################
# WAIT FOR EBS DISK
########################################

echo "Waiting for EBS disk..."

ROOT_DISK=$(lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -n1)
if [ -z "$ROOT_DISK" ]; then
  ROOT_DISK=$(lsblk -dn -o NAME | head -n1)
fi

DEVICE=""
for i in {1..30}; do
  DEVICE=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^$${ROOT_DISK}$" | head -n1)
  if [ -n "$DEVICE" ]; then
    DEVICE="/dev/$DEVICE"
    break
  fi
  sleep 5
done

if [ -z "$DEVICE" ]; then
  echo "No EBS disk found"
  exit 1
fi

echo "Using $DEVICE"

mkfs -t ext4 -F $DEVICE
mkdir -p /data
mount $DEVICE /data
echo "$DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab

########################################
# REMOVE DEFAULT UBUNTU CLUSTER
########################################

# Stop, disable, and mask the default Ubuntu postgresql service so it
# can never restart and conflict with our custom data directory.
systemctl stop postgresql || true
systemctl disable postgresql || true
systemctl mask postgresql || true
# Also mask the instance unit — on Ubuntu 22.04 the actual running service
# is postgresql@14-main.service, which can restart independently of the
# postgresql.service meta-unit if only the meta-unit is masked.
systemctl stop "postgresql@${PG_VERSION}-main" || true
systemctl disable "postgresql@${PG_VERSION}-main" || true
systemctl mask "postgresql@${PG_VERSION}-main" || true

rm -rf /var/lib/postgresql/$PG_VERSION/main || true
rm -rf /etc/postgresql/$PG_VERSION/main || true

mkdir -p /data/pgdata
chown -R postgres:postgres /data
chmod 700 /data/pgdata

########################################
# CREATE .pgpass FOR pg_basebackup
########################################

# Use * for the database field so this entry matches both the replication
# protocol connection (pg_basebackup) and the postgres-database psql check
# that waits for the replication user. A database-specific entry of
# "replication" would cause the psql check to never find the password and
# loop forever, stalling the entire script before pg_basebackup ever runs.
echo "$PRIMARY_IP:5432:*:$REPL_USER:$REPL_PASS" > /var/lib/postgresql/.pgpass
chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

########################################
# WAIT FOR PRIMARY POSTGRESQL
########################################

echo "Waiting for primary PostgreSQL to be ready..."
until pg_isready -h $PRIMARY_IP -p 5432; do
  echo "  primary not ready, retrying in 5s..."
  sleep 5
done

########################################
# WAIT FOR REPLICATION USER
# pg_isready only confirms the port is open — the replication user is
# created a few seconds after PostgreSQL starts on the primary.
########################################

echo "Waiting for replication user on primary..."
until sudo -u postgres PGPASSFILE=/var/lib/postgresql/.pgpass \
  psql -h $PRIMARY_IP -p 5432 -U $REPL_USER -d postgres -c "SELECT 1" > /dev/null 2>&1; do
  echo "  replication user not ready yet, retrying in 10s..."
  sleep 10
done

########################################
# RUN BASEBACKUP WITH RETRIES
# -X stream opens a second connection to stream WAL during the backup
# so there is no WAL gap between the snapshot and replication start.
########################################

echo "Running pg_basebackup..."

for attempt in {1..10}; do
  rm -rf /data/pgdata && mkdir -p /data/pgdata
  chown postgres:postgres /data/pgdata && chmod 700 /data/pgdata

  if sudo -u postgres PGPASSFILE=/var/lib/postgresql/.pgpass \
    pg_basebackup \
      -h $PRIMARY_IP \
      -D /data/pgdata \
      -U $REPL_USER \
      -P \
      -R \
      -X stream \
      -S replica_slot; then
    echo "pg_basebackup succeeded on attempt $attempt."
    break
  fi

  echo "pg_basebackup failed (attempt $attempt/10), retrying in 15s..."
  sleep 15

  if [ "$attempt" -eq 10 ]; then
    echo "pg_basebackup failed after 10 attempts — aborting."
    exit 1
  fi
done

########################################
# VERIFY STANDBY SIGNAL FILE
# pg_basebackup -R should create standby.signal. Without it PostgreSQL
# starts as a primary, not a standby, and replication never initiates.
########################################

if [ ! -f /data/pgdata/standby.signal ]; then
  echo "ERROR: standby.signal not found — pg_basebackup -R did not complete correctly"
  exit 1
fi

########################################
# WRITE PRIMARY_CONNINFO WITH EXPLICIT PASSWORD
# pg_basebackup -R writes primary_conninfo to postgresql.auto.conf but
# does NOT include the password. When the replica PostgreSQL process
# starts it needs credentials to begin streaming. We overwrite the entry
# with an explicit password and application_name so the connection works
# without relying on .pgpass lookups at runtime.
########################################

echo "Writing primary_conninfo with credentials..."

# Remove any primary_conninfo / primary_slot_name lines written by pg_basebackup
sed -i "/^primary_conninfo/d;/^primary_slot_name/d" /data/pgdata/postgresql.auto.conf

cat >> /data/pgdata/postgresql.auto.conf <<EOF
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=$REPL_USER password=$REPL_PASS application_name=replica'
primary_slot_name = 'replica_slot'
EOF

chown postgres:postgres /data/pgdata/postgresql.auto.conf

########################################
# SYSTEMD SERVICE
########################################

echo "Registering systemd service for reboot persistence..."

cat > /etc/systemd/system/postgresql-custom.service <<UNIT
[Unit]
Description=PostgreSQL $PG_VERSION Custom Data Directory
After=network.target

[Service]
Type=forking
User=postgres
PIDFile=/data/pgdata/postmaster.pid
ExecStart=/usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/pgdata -l /data/pgdata/logfile start
ExecStop=/usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/pgdata stop
ExecReload=/usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/pgdata reload
TimeoutSec=300

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable postgresql-custom

########################################
# START REPLICA
########################################

echo "Starting replica..."
systemctl start postgresql-custom

# Confirm replication is streaming
sleep 5
sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_isready -q && \
  echo "Replica is up." || echo "WARNING: replica did not start cleanly — check /data/pgdata/logfile"

echo "Replica setup complete."
