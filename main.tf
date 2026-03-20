provider "aws" {
  region = var.region
}

#####################################
# AMI
#####################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

#####################################
# NETWORK
#####################################

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "assoc" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.rt.id
}

#####################################
# SECURITY GROUP
#####################################

resource "aws_security_group" "postgres_sg" {
  name   = "postgres-sg"
  vpc_id = aws_vpc.main.id

  # SSH — restrict to your IP in production via var.ssh_cidr
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  # PostgreSQL — restricted to VPC CIDR by default
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#####################################
# PRIMARY
#####################################

resource "aws_instance" "primary" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.postgres_sg.id]
  key_name               = var.key_name
  user_data = templatefile("${path.module}/user-data-primary.sh", {
    repl_pass = var.repl_pass
  })

  tags = {
    Name = "pg-primary"
  }
}

resource "aws_ebs_volume" "primary_data" {
  availability_zone = aws_instance.primary.availability_zone
  size              = 10
  type              = "gp3"
  encrypted         = true
}

resource "aws_volume_attachment" "primary_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.primary_data.id
  instance_id = aws_instance.primary.id
}

#####################################
# REPLICA
#####################################

resource "aws_instance" "replica" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.postgres_sg.id]
  key_name               = var.key_name

  user_data = templatefile("${path.module}/user-data-replica.sh", {
    primary_ip = aws_instance.primary.private_ip
    repl_pass  = var.repl_pass
  })

  tags = {
    Name = "pg-replica"
  }
}

resource "aws_ebs_volume" "replica_data" {
  availability_zone = aws_instance.replica.availability_zone
  size              = 10
  type              = "gp3"
  encrypted         = true
}

resource "aws_volume_attachment" "replica_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.replica_data.id
  instance_id = aws_instance.replica.id
}

#####################################
# OUTPUTS
#####################################

output "primary_public_ip" {
  value = aws_instance.primary.public_ip
}

output "replica_public_ip" {
  value = aws_instance.replica.public_ip
}