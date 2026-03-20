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

# Identify root disk device and exclude it so we only format the attached EBS volume
ROOT_DISK=$(lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -n1)
if [ -z "$ROOT_DISK" ]; then
  ROOT_DISK=$(lsblk -dn -o NAME | head -n1)
fi

DEVICE=""
for i in {1..30}; do
  DEVICE=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^${ROOT_DISK}$" | head -n1)
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
# REMOVE DEFAULT UBUNTU CLUSTER COMPLETELY
########################################

systemctl stop postgresql || true

rm -rf /var/lib/postgresql/$PG_VERSION/main || true
rm -rf /etc/postgresql/$PG_VERSION/main || true

mkdir -p /data/pgdata
chown -R postgres:postgres /data
chmod 700 /data/pgdata

########################################
# CREATE .pgpass
########################################

echo "$PRIMARY_IP:5432:*:$REPL_USER:$REPL_PASS" > /var/lib/postgresql/.pgpass
chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass

########################################
# WAIT FOR PRIMARY
########################################

echo "Waiting for primary..."

until pg_isready -h $PRIMARY_IP -p 5432; do
  sleep 5
done

########################################
# RUN BASEBACKUP
########################################

echo "Running pg_basebackup..."

sudo -u postgres pg_basebackup \
  -h $PRIMARY_IP \
  -D /data/pgdata \
  -U $REPL_USER \
  -P \
  -R \
  -S replica_slot

########################################
# REGISTER SYSTEMD SERVICE FOR REBOOT PERSISTENCE
########################################

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

########################################
# START REPLICA
########################################

echo "Starting replica..."

systemctl start postgresql-custom

echo "Replica setup complete."
