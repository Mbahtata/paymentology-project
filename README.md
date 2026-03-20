# Paymentology PostgreSQL Infrastructure

Terraform project that provisions a PostgreSQL 14 primary/replica streaming replication setup on AWS EC2.

## Architecture

- VPC with public subnet
- Two EC2 instances (primary + replica) running Ubuntu 22.04
- 10GB encrypted gp3 EBS volume attached to each instance
- PostgreSQL streaming replication via `pg_basebackup`
- Replication slot for zero data loss

## CI/CD

GitHub Actions runs `terraform plan` on every PR and `terraform apply` on merge to `main`.
A separate manual `Terraform Destroy` workflow tears down all resources — requires typing `destroy` as confirmation.

## Verifying Replication

After deployment SSH into each instance and run:

```bash
# Primary — should show one active streaming row
sudo -u postgres psql -c "SELECT client_addr, state FROM pg_stat_replication;"

# Replica — should show status = streaming
sudo -u postgres psql -c "SELECT status, sender_host FROM pg_stat_wal_receiver;"
```

## Usage

```bash
terraform init \
  -backend-config="bucket=paymentology-tf-state-562578955205" \
  -backend-config="key=paymentology/terraform.tfstate" \
  -backend-config="region=us-east-1"

terraform plan -var="repl_pass=<password>"
terraform apply -var="repl_pass=<password>"
```
