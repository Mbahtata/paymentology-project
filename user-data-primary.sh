#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data-primary.log) 2>&1

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
# INITIALISE DATA DIRECTORY
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

echo "Removing default cluster completely..."
rm -rf /var/lib/postgresql/$PG_VERSION/main
rm -rf /etc/postgresql/$PG_VERSION/main

mkdir -p /data/pgdata
chown -R postgres:postgres /data
chmod 700 /data/pgdata

echo "Initialising database..."
sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D /data/pgdata

########################################
# CONFIGURE PRIMARY
########################################

cat >> /data/pgdata/postgresql.conf <<EOF

# Replication
wal_level             = replica
max_wal_senders       = 10
max_replication_slots = 10
hot_standby           = on

# WAL archiving — disabled; streaming replication does not require it
archive_mode          = off
archive_command       = ''

# Connections
listen_addresses      = '*'

# Authentication — must match pg_hba.conf method below
password_encryption   = md5
EOF

# pg_hba.conf — append after initdb defaults so our rules take effect for
# VPC connections. md5 matches password_encryption = md5 set above.
cat >> /data/pgdata/pg_hba.conf <<EOF

# VPC replication and general access
host  replication  $REPL_USER  10.0.0.0/16  md5
host  all          all         10.0.0.0/16  md5
EOF

########################################
# SYSTEMD SERVICE
########################################

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

echo "Starting PostgreSQL..."
systemctl start postgresql-custom

########################################
# WAIT UNTIL POSTGRESQL IS ACCEPTING CONNECTIONS
########################################

echo "Waiting for PostgreSQL to accept connections..."
until sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_isready -q; do
  echo "  not ready yet, retrying in 2s..."
  sleep 2
done

########################################
# CREATE REPLICATION USER AND SLOT
# Use psql dollar-quoting ($$) so passwords containing single quotes
# or other special characters do not break the SQL statement.
########################################

echo "Creating replication user..."
sudo -u postgres psql -v repl_user="$REPL_USER" -v repl_pass="$REPL_PASS" <<'SQL'
CREATE ROLE :"repl_user" WITH REPLICATION LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'repl_pass';
SELECT pg_create_physical_replication_slot('replica_slot');
SQL

echo "Primary setup complete."
