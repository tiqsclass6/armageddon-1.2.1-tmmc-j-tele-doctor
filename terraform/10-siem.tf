######################################################################
#  SIEM SUBNETS — restricted AZs, different from DB subnets
#  CIDRs: 10.230.60.0/24 and 10.230.61.0/24 (local.syslog_cidr /23)
######################################################################
resource "aws_subnet" "siem_subnet_tokyo" {
  vpc_id            = aws_vpc.tokyo.id
  count             = length(var.vpc_az_tokyo_restricted)
  cidr_block        = cidrsubnet(aws_vpc.tokyo.cidr_block, 8, count.index + 60)
  availability_zone = element(var.vpc_az_tokyo_restricted, count.index)
  provider          = aws.tokyo

  tags = {
    Name = "Tokyo SIEM Subnet${count.index + 1}"
  }
}

resource "aws_route_table_association" "tokyo_siem_subnet_association" {
  route_table_id = aws_route_table.tokyo_route_table_security_subnet.id
  count          = length(var.vpc_az_tokyo_restricted)
  subnet_id      = element(aws_subnet.siem_subnet_tokyo[*].id, count.index)
  provider       = aws.tokyo
}

######################################################################
#  S3 Buckets (syslog archive in Japan; Osaka replica is still Japan)
######################################################################
resource "random_string" "bucket_name" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "SyslogBucket" {
  bucket   = "syslog-bucket-${random_string.bucket_name.result}"
  provider = aws.tokyo

  tags = {
    Name = "Syslog S3 Bucket"
  }
}

resource "aws_s3_bucket" "destination" {
  bucket   = "destination-${random_string.bucket_name.result}"
  provider = aws.osaka

  tags = {
    Name = "Destination Bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "SyslogBucket" {
  bucket                  = aws_s3_bucket.SyslogBucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  provider                = aws.tokyo
}

resource "aws_s3_bucket_server_side_encryption_configuration" "SyslogBucket" {
  bucket   = aws_s3_bucket.SyslogBucket.id
  provider = aws.tokyo

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

######################################################################
#  S3 Bucket Versioning
######################################################################
resource "aws_s3_bucket_versioning" "versioning" {
  bucket   = aws_s3_bucket.SyslogBucket.id
  provider = aws.tokyo

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "destination" {
  bucket   = aws_s3_bucket.destination.id
  provider = aws.osaka

  versioning_configuration {
    status = "Enabled"
  }
}

######################################################################
#  S3 Replication IAM Role + Policy
######################################################################
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "replication" {
  name               = "tf-iam-role-replication-syslog"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "replication" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]

    resources = [aws_s3_bucket.SyslogBucket.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]

    resources = ["${aws_s3_bucket.SyslogBucket.arn}/*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]

    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }
}

resource "aws_iam_policy" "replication" {
  name   = "tf-iam-role-policy-replication-syslog"
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_iam_role_policy_attachment" "replication" {
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}

######################################################################
#  S3 Bucket Replication Configuration (Tokyo -> Osaka, both Japan)
######################################################################
resource "aws_s3_bucket_replication_configuration" "replication" {
  provider = aws.tokyo

  depends_on = [
    aws_s3_bucket_versioning.versioning,
    aws_s3_bucket_versioning.destination
  ]

  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.SyslogBucket.id

  rule {
    id     = "replication-rule"
    status = "Enabled"

    filter {
      prefix = ""
    }

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.destination.arn
      storage_class = "STANDARD"
    }
  }
}

resource "aws_s3_bucket_policy" "SyslogBucketPolicy" {
  provider = aws.tokyo
  bucket   = aws_s3_bucket.SyslogBucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowPutObjectFromSIEMInstanceRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.siem_instance_role.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.SyslogBucket.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-server-side-encryption" = "AES256"
          }
        }
      }
    ]
  })
}

######################################################################
#  A.3 Security Groups
#  Spokes may send Loki (3100). They cannot reach Grafana (3000) or SSH.
######################################################################
resource "aws_security_group" "siem_nlb_sg" {
  name        = "siem-nlb-sg"
  description = "Loki ingest NLB: TCP 3100 from spokes + Tokyo only"
  vpc_id      = aws_vpc.tokyo.id
  provider    = aws.tokyo

  ingress {
    description = "Loki push from spoke VPCs"
    from_port   = local.loki_ingest_port
    to_port     = local.loki_ingest_port
    protocol    = "tcp"
    cidr_blocks = local.spoke_cidrs
  }

  ingress {
    description = "Loki push from Tokyo VPC"
    from_port   = local.loki_ingest_port
    to_port     = local.loki_ingest_port
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.tokyo.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SIEM NLB SG (send-only ingest)"
  }
}

resource "aws_security_group" "siem_grafana_alb_sg" {
  name        = "siem-grafana-alb-sg"
  description = "Grafana ALB: Tokyo VPC only, spokes denied"
  vpc_id      = aws_vpc.tokyo.id
  provider    = aws.tokyo

  ingress {
    description = "Grafana from Tokyo only"
    from_port   = local.grafana_port
    to_port     = local.grafana_port
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.tokyo.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SIEM Grafana ALB SG (Tokyo only)"
  }
}

resource "aws_security_group" "siem_sg" {
  name        = "siem-sg"
  description = "SIEM instances: ingest from NLB, Grafana from internal ALB, no SSH"
  vpc_id      = aws_vpc.tokyo.id
  provider    = aws.tokyo

  ingress {
    description     = "Loki from ingest NLB"
    from_port       = local.loki_ingest_port
    to_port         = local.loki_ingest_port
    protocol        = "tcp"
    security_groups = [aws_security_group.siem_nlb_sg.id]
  }

  ingress {
    description     = "Grafana from internal ALB"
    from_port       = local.grafana_port
    to_port         = local.grafana_port
    protocol        = "tcp"
    security_groups = [aws_security_group.siem_grafana_alb_sg.id]
  }

  egress {
    description = "HTTPS for package install via NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP for package mirrors"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SIEM Security Group"
  }
}

######################################################################
#  NACL: extra deny of Grafana/SSH from spoke CIDRs (A.3 / A.4)
######################################################################
resource "aws_network_acl" "siem" {
  vpc_id     = aws_vpc.tokyo.id
  subnet_ids = aws_subnet.siem_subnet_tokyo[*].id
  provider   = aws.tokyo

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.224.0.0/12"
    from_port  = local.loki_ingest_port
    to_port    = local.loki_ingest_port
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = aws_vpc.tokyo.cidr_block
    from_port  = local.grafana_port
    to_port    = local.grafana_port
  }

  ingress {
    rule_no    = 115
    protocol   = "tcp"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = local.grafana_port
    to_port    = local.grafana_port
  }

  ingress {
    rule_no    = 116
    protocol   = "tcp"
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 22
    to_port    = 22
  }

  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  egress {
    rule_no    = 120
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }

  # Return for Loki/Grafana clients
  egress {
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.224.0.0/12"
    from_port  = 1024
    to_port    = 65535
  }

  tags = {
    Name = "SIEM NACL send-only"
  }
}

######################################################################
#  Loki ingest NLB (internal) — spokes send here
######################################################################
resource "aws_lb" "siem_nlb" {
  name                             = "tokyo-siem-loki-nlb"
  load_balancer_type               = "network"
  internal                         = true
  subnets                          = aws_subnet.siem_subnet_tokyo[*].id
  security_groups                  = [aws_security_group.siem_nlb_sg.id]
  enable_cross_zone_load_balancing = true
  provider                         = aws.tokyo

  tags = {
    Name = "SIEM Loki NLB"
  }
}

resource "aws_lb_target_group" "siem_loki_tg" {
  name        = "siem-loki-tg"
  port        = local.loki_ingest_port
  protocol    = "TCP"
  vpc_id      = aws_vpc.tokyo.id
  target_type = "instance"
  provider    = aws.tokyo

  health_check {
    enabled  = true
    protocol = "TCP"
    port     = tostring(local.loki_ingest_port)
  }

  tags = {
    Name = "SIEM Loki TG"
  }
}

resource "aws_lb_listener" "siem_loki" {
  load_balancer_arn = aws_lb.siem_nlb.arn
  port              = local.loki_ingest_port
  protocol          = "TCP"
  provider          = aws.tokyo

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.siem_loki_tg.arn
  }
}

######################################################################
#  Grafana internal ALB — Tokyo only
######################################################################
resource "aws_lb" "siem_grafana_alb" {
  name               = "tokyo-siem-grafana-alb"
  load_balancer_type = "application"
  internal           = true
  subnets            = aws_subnet.siem_subnet_tokyo[*].id
  security_groups    = [aws_security_group.siem_grafana_alb_sg.id]
  provider           = aws.tokyo

  tags = {
    Name = "SIEM Grafana ALB"
  }
}

resource "aws_lb_target_group" "siem_grafana_tg" {
  name        = "siem-grafana-tg"
  port        = local.grafana_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.tokyo.id
  target_type = "instance"
  provider    = aws.tokyo

  health_check {
    enabled             = true
    path                = "/login"
    protocol            = "HTTP"
    port                = tostring(local.grafana_port)
    matcher             = "200"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name = "SIEM Grafana TG"
  }
}

resource "aws_lb_listener" "siem_grafana" {
  load_balancer_arn = aws_lb.siem_grafana_alb.arn
  port              = local.grafana_port
  protocol          = "HTTP"
  provider          = aws.tokyo

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.siem_grafana_tg.arn
  }
}

######################################################################
#  SIEM Server Launch Template (A.2 basic EC2)
######################################################################
resource "aws_launch_template" "siem_server_lt" {
  name_prefix            = "siem-server-lt-"
  image_id               = data.aws_ami.al2023_tokyo.id
  instance_type          = "t3.medium"
  vpc_security_group_ids = [aws_security_group.siem_sg.id]
  provider               = aws.tokyo

  iam_instance_profile {
    name = aws_iam_instance_profile.siem_instance_profile.name
  }

  user_data = filebase64("${path.module}/../scripts/2-grafana.sh")

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "SIEM_Server"
    }
  }
}

######################################################################
#  ASG across two restricted AZs (A.1 fault tolerant, A.2 still basic EC2)
######################################################################
resource "aws_autoscaling_group" "siem_asg" {
  launch_template {
    id      = aws_launch_template.siem_server_lt.id
    version = "$Latest"
  }

  vpc_zone_identifier = aws_subnet.siem_subnet_tokyo[*].id
  target_group_arns = [
    aws_lb_target_group.siem_loki_tg.arn,
    aws_lb_target_group.siem_grafana_tg.arn,
  ]
  min_size                  = 2
  max_size                  = 2
  desired_capacity          = 2
  health_check_type         = "EC2"
  health_check_grace_period = 300
  provider                  = aws.tokyo

  tag {
    key                 = "Name"
    value               = "SIEM_Server"
    propagate_at_launch = true
  }
}

######################################################################
#  IAM Role + Instance Profile for SIEM Server
######################################################################
resource "aws_iam_role" "siem_instance_role" {
  name = "SIEMInstanceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "siem_instance_policy" {
  name        = "SIEMInstancePolicy"
  description = "SIEM instances may archive syslog to S3 in Japan"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.SyslogBucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "siem_instance_s3" {
  role       = aws_iam_role.siem_instance_role.name
  policy_arn = aws_iam_policy.siem_instance_policy.arn
}

resource "aws_iam_role_policy_attachment" "siem_instance_ssm" {
  role       = aws_iam_role.siem_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "siem_instance_profile" {
  name = "SIEMInstanceProfile"
  role = aws_iam_role.siem_instance_role.name
}
