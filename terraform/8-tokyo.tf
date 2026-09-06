# VPC
resource "aws_vpc" "tokyo" {
  cidr_block           = "10.230.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  provider             = aws.tokyo
  tags = {
    Name = "Tokyo VPC"
  }
}

# Subnets
resource "aws_subnet" "public_subnet_tokyo" {
  vpc_id            = aws_vpc.tokyo.id
  count             = length(var.vpc_az_tokyo)
  cidr_block        = cidrsubnet(aws_vpc.tokyo.cidr_block, 8, count.index + 1)
  availability_zone = element(var.vpc_az_tokyo, count.index)
  provider          = aws.tokyo
  tags = {
    Name = "Tokyo Public Subnet${count.index + 1}",
  }
}

resource "aws_subnet" "private_subnet_tokyo" {
  vpc_id            = aws_vpc.tokyo.id
  count             = length(var.vpc_az_tokyo)
  cidr_block        = cidrsubnet(aws_vpc.tokyo.cidr_block, 8, count.index + 11)
  availability_zone = element(var.vpc_az_tokyo, count.index)
  provider          = aws.tokyo
  tags = {
    Name = "Tokyo Private Subnet${count.index + 1}",
  }
}
# PII DB subnets in restricted AZs only (no public subnets in 1d/1b).
resource "aws_subnet" "db_subnet_tokyo" {
  vpc_id            = aws_vpc.tokyo.id
  count             = length(var.vpc_az_tokyo_restricted)
  cidr_block        = cidrsubnet(aws_vpc.tokyo.cidr_block, 8, count.index + 51)
  availability_zone = element(var.vpc_az_tokyo_restricted, count.index)
  provider          = aws.tokyo
  tags = {
    Name = "Tokyo RDS Subnet${count.index + 1}",
  }
}
# IGW
resource "aws_internet_gateway" "tokyo_igw" {
  vpc_id   = aws_vpc.tokyo.id
  provider = aws.tokyo

  tags = {
    Name = "tokyo_igw"
  }
}

# RT for the public subnet
resource "aws_route_table" "tokyo_route_table_public_subnet" {
  vpc_id   = aws_vpc.tokyo.id
  provider = aws.tokyo

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.tokyo_igw.id
  }

  tags = {
    Name = "Route Table for Public Subnet",
  }
}

# Association between RT and IG
resource "aws_route_table_association" "tokyo_public_subnet_association" {
  route_table_id = aws_route_table.tokyo_route_table_public_subnet.id
  count          = length((var.vpc_az_tokyo))
  subnet_id      = element(aws_subnet.public_subnet_tokyo[*].id, count.index)
  provider       = aws.tokyo
}

# EIP
resource "aws_eip" "tokyo_eip" {
  domain   = "vpc"
  provider = aws.tokyo
}

# NAT
resource "aws_nat_gateway" "tokyo_nat" {
  allocation_id = aws_eip.tokyo_eip.id
  subnet_id     = aws_subnet.public_subnet_tokyo[0].id
  provider      = aws.tokyo
}

# RT for private Subnet
resource "aws_route_table" "tokyo_route_table_private_subnet" {
  vpc_id   = aws_vpc.tokyo.id
  provider = aws.tokyo

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.tokyo_nat.id
  }

  tags = {
    Name = "Route Table for App Private Subnet",
  }

}

# Restricted-AZ route table: SIEM + DB. NAT for SIEM bootstrap only.
# Spoke CIDRs are added via aws_route in the TGW files (return path for syslog).
resource "aws_route_table" "tokyo_route_table_security_subnet" {
  vpc_id   = aws_vpc.tokyo.id
  provider = aws.tokyo

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.tokyo_nat.id
  }

  tags = {
    Name = "Route Table for Restricted Private AZs",
  }
}

# RT Association Private
resource "aws_route_table_association" "tokyo_private_subnet_association" {
  route_table_id = aws_route_table.tokyo_route_table_private_subnet.id
  count          = length((var.vpc_az_tokyo))
  subnet_id      = element(aws_subnet.private_subnet_tokyo[*].id, count.index)
  provider       = aws.tokyo
}

resource "aws_route_table_association" "tokyo_db_subnet_association" {
  route_table_id = aws_route_table.tokyo_route_table_security_subnet.id
  count          = length(var.vpc_az_tokyo_restricted)
  subnet_id      = element(aws_subnet.db_subnet_tokyo[*].id, count.index)
  provider       = aws.tokyo
}

# Security Groups
resource "aws_security_group" "tokyo_alb_sg" {
  name        = "tokyo-alb-sg"
  description = "Security Group for Application Load Balancer"
  provider    = aws.tokyo

  vpc_id = aws_vpc.tokyo.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "tokyo-alb-sg"
  }
}

# Security Group For EC2
resource "aws_security_group" "tokyo_ec2_sg" {
  name        = "tokyo-ec2-sg"
  description = "Security Group for Webserver Instance"
  provider    = aws.tokyo

  vpc_id = aws_vpc.tokyo.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "TCP"
    security_groups = [aws_security_group.tokyo_alb_sg.id]

  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tokyo-ec2-sg"
  }
}

# Load Balancer
resource "aws_lb" "tokyo_alb" {
  name                       = "tokyo-load-balancer"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public_subnet_tokyo[*].id
  security_groups            = [aws_security_group.tokyo_alb_sg.id]
  depends_on                 = [aws_internet_gateway.tokyo_igw]
  enable_deletion_protection = false
  provider                   = aws.tokyo

  tags = {
    Name    = "tokyoLoadBalancer"
    Service = "tokyo"
  }
}

# Target Group
resource "aws_lb_target_group" "tokyo-tg" {
  name        = "tokyo-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.tokyo.id
  provider    = aws.tokyo
  target_type = "instance"

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 2
    timeout             = 5
    matcher             = "200"
  }

  tags = {
    Name    = "tokyo-tg"
    Service = "TokyoTG"
  }
}

# Listener
resource "aws_lb_listener" "tokyo_http" {
  load_balancer_arn = aws_lb.tokyo_alb.arn
  port              = 80
  protocol          = "HTTP"
  provider          = aws.tokyo

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tokyo-tg.arn
  }
}

# Launch Template
resource "aws_launch_template" "tokyo_LT" {
  provider      = aws.tokyo
  name_prefix   = "tokyo_LT"
  image_id      = data.aws_ami.al2023_tokyo.id
  instance_type = "t2.micro"

  user_data = base64encode(templatefile("${path.module}/../scripts/1-user-data.sh", {
    loki_push_host = aws_lb.siem_nlb.dns_name
  }))

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.tokyo_ec2_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "tokyo-ec2-web-server"
    }
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "tokyo_asg" {
  max_size            = 3
  min_size            = 2
  desired_capacity    = 2
  name                = "tokyo-web-server-asg"
  target_group_arns   = [aws_lb_target_group.tokyo-tg.arn]
  vpc_zone_identifier = aws_subnet.private_subnet_tokyo[*].id
  provider            = aws.tokyo

  launch_template {
    id      = aws_launch_template.tokyo_LT.id
    version = "$Latest"
  }

  health_check_type = "EC2"
}