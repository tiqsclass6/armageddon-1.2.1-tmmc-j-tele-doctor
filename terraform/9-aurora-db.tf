######################################################################
# Aurora PostgreSQL in Tokyo restricted AZs (PII stays in Japan)
# Not in SIEM subnets. No public subnet in these AZs.
######################################################################

resource "random_password" "aurora_master" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}"
}

data "aws_rds_engine_version" "aurora_pg" {
  provider = aws.tokyo
  engine   = "aurora-postgresql"
  # v6: latest avoids "multiple RDS engine versions" that default_only can still hit.
  latest = true
}

resource "aws_db_subnet_group" "aurora_tokyo" {
  name       = "aurora-tokyo-restricted"
  subnet_ids = aws_subnet.db_subnet_tokyo[*].id
  provider   = aws.tokyo

  tags = {
    Name = "Aurora restricted-AZ subnet group"
  }
}

resource "aws_security_group" "aurora_sg" {
  name        = "aurora-sg"
  description = "Aurora PII: Tokyo app private instances only, no spoke access"
  vpc_id      = aws_vpc.tokyo.id
  provider    = aws.tokyo

  ingress {
    description     = "Postgres from Tokyo web ASG"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.tokyo_ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aurora-sg"
  }
}

resource "aws_rds_cluster_parameter_group" "aurora_parameter_group" {
  name     = "aurora-cluster-parameter-group"
  family   = data.aws_rds_engine_version.aurora_pg.parameter_group_family
  provider = aws.tokyo

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_rds_cluster" "aurora_cluster" {
  cluster_identifier              = "aurora-postgres-cluster"
  engine                          = data.aws_rds_engine_version.aurora_pg.engine
  engine_version                  = data.aws_rds_engine_version.aurora_pg.version_actual
  engine_mode                     = "provisioned"
  database_name                   = "tmmedb"
  master_username                 = "tmmeadmin"
  master_password                 = random_password.aurora_master.result
  db_subnet_group_name            = aws_db_subnet_group.aurora_tokyo.name
  vpc_security_group_ids          = [aws_security_group.aurora_sg.id]
  storage_encrypted               = true
  backup_retention_period         = 7
  preferred_backup_window         = "07:00-09:00"
  skip_final_snapshot             = true
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora_parameter_group.name
  provider                        = aws.tokyo

  tags = {
    Name = "aurora-postgres-cluster"
  }
}

resource "aws_rds_cluster_instance" "aurora_cluster_instances" {
  count              = 2
  identifier         = "aurora-postgres-instance-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.aurora_cluster.id
  instance_class     = "db.t3.medium"
  engine             = aws_rds_cluster.aurora_cluster.engine
  availability_zone  = var.vpc_az_tokyo_restricted[count.index]
  provider           = aws.tokyo

  tags = {
    Name = "aurora-postgres-instance-${count.index + 1}"
  }
}
