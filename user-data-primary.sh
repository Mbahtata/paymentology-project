#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data-primary.log) 2>&1

PG_VERSION=14
REPL_USER="replicator"
REPL_PASS="${repl_pass}"

echo "Installing PostgreSQL..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y postgresql-$PG_VERSION

echo "Waiting for EBS disk..."

# Identify root disk device and exclude it so we only format the attached EBS volume
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

systemctl stop postgresql || true

echo "Removing default cluster completely..."
rm -rf /var/lib/postgresql/$PG_VERSION/main
rm -rf /etc/postgresql/$PG_VERSION/main

mkdir -p /data/pgdata
chown -R postgres:postgres /data
chmod 700 /data/pgdata

echo "Initializing database manually..."

sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D /data/pgdata

echo "Configuring primary..."

cat >> /data/pgdata/postgresql.conf <<EOF
listen_addresses='*'
wal_level=replica
max_wal_senders=10
max_replication_slots=10
EOF

cat >> /data/pgdata/pg_hba.conf <<EOF
host replication $REPL_USER 10.0.0.0/16 md5
host all all 10.0.0.0/16 md5
EOF

echo "Registering systemd service for reboot persistence..."

cat > /etc/systemd/system/postgresql-custom.service <<UNIT
[Unit]
Description=PostgreSQL $PG_VERSION Custom Data Directory
After=network.target

[Service]
Type=forking
User=postgres
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

sleep 5

echo "Creating replication user..."

sudo -u postgres psql -c "CREATE ROLE $REPL_USER WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';"
sudo -u postgres psql -c "SELECT pg_create_physical_replication_slot('replica_slot');"

echo "Primary setup complete."
