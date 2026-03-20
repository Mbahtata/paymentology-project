variable "region" {
  default = "us-east-1"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "allowed_cidr" {
  description = "CIDR allowed to access PostgreSQL"
  default     = "10.0.0.0/16"
}

variable "ssh_cidr" {
  description = "CIDR allowed SSH access (use your IP in production)"
  default     = "0.0.0.0/0"
}

variable "key_name" {
  description = "Existing AWS key pair"
  default     = "argocd-project"
}

variable "repl_pass" {
  description = "Password for the PostgreSQL replication user — override in tfvars or via TF_VAR_repl_pass"
  sensitive   = true
  default     = "StrongPass123"
}