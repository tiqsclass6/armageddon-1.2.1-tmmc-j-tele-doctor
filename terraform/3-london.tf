###########################################################
# VPC
###########################################################

resource "aws_vpc" "london" {
  cidr_block           = "10.232.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  provider             = aws.london
  tags = {
    Name = "London VPC"
  }
}

# Subnets
resource "aws_subnet" "public_subnet_london" {
  vpc_id            = aws_vpc.london.id
  count             = length(var.vpc_az_london)
  cidr_block        = cidrsubnet(aws_vpc.london.cidr_block, 8, count.index + 1)
  availability_zone = element(var.vpc_az_london, count.index)
  provider          = aws.london
  tags = {
    Name = "London Public Subnet${count.index + 1}",
  }
}

resource "aws_subnet" "private_subnet_london" {
  vpc_id            = aws_vpc.london.id
  count             = length(var.vpc_az_london)
  cidr_block        = cidrsubnet(aws_vpc.london.cidr_block, 8, count.index + 11)
  availability_zone = element(var.vpc_az_london, count.index)
  provider          = aws.london
  tags = {
    Name = "London Private Subnet${count.index + 1}",
  }
}

# IGW
resource "aws_internet_gateway" "london_igw" {
  vpc_id   = aws_vpc.london.id
  provider = aws.london

  tags = {
    Name = "london_igw"
  }
}

# RT for the public subnet
resource "aws_route_table" "london_route_table_public_subnet" {
  vpc_id   = aws_vpc.london.id
  provider = aws.london

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.london_igw.id
  }

  tags = {
    Name = "Route Table for Public Subnet",
  }

}

# Association between RT and IG
resource "aws_route_table_association" "london_public_subnet_association" {
  route_table_id = aws_route_table.london_route_table_public_subnet.id
  count          = length((var.vpc_az_london))
  subnet_id      = element(aws_subnet.public_subnet_london[*].id, count.index)
  provider       = aws.london
}

# EIP
resource "aws_eip" "london_eip" {
  domain   = "vpc"
  provider = aws.london
}

# NAT
resource "aws_nat_gateway" "london_nat" {
  allocation_id = aws_eip.london_eip.id
  subnet_id     = aws_subnet.public_subnet_london[0].id
  provider      = aws.london
}

# RT for private Subnet
resource "aws_route_table" "london_route_table_private_subnet" {
  vpc_id   = aws_vpc.london.id
  provider = aws.london

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.london_nat.id
  }

  route {
    cidr_block         = local.syslog_cidr
    transit_gateway_id = aws_ec2_transit_gateway.local_london.id
  }

  tags = {
    Name = "Route Table for Private Subnet",
  }

}

# RT Association Private
resource "aws_route_table_association" "london_private_subnet_association" {
  route_table_id = aws_route_table.london_route_table_private_subnet.id
  count          = length((var.vpc_az_london))
  subnet_id      = element(aws_subnet.private_subnet_london[*].id, count.index)
  provider       = aws.london
}

# Security Groups
resource "aws_security_group" "london_alb_sg" {
  name        = "london-alb-sg"
  description = "Security Group for Application Load Balancer"
  provider    = aws.london

  vpc_id = aws_vpc.london.id

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
    Name = "london-alb-sg"
  }
}

# Security Group For EC2

resource "aws_security_group" "london_ec2_sg" {
  name        = "london-ec2-sg"
  description = "Security Group for Webserver Instance"
  provider    = aws.london

  vpc_id = aws_vpc.london.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "TCP"
    security_groups = [aws_security_group.london_alb_sg.id]

  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "london-ec2-sg"
  }
}

# Load Balancer
resource "aws_lb" "london_alb" {
  name                       = "london-load-balancer"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public_subnet_london[*].id
  security_groups            = [aws_security_group.london_alb_sg.id]
  depends_on                 = [aws_internet_gateway.london_igw]
  enable_deletion_protection = false
  provider                   = aws.london

  tags = {
    Name    = "londonLoadBalancer"
    Service = "london"
  }
}

# Target Group
resource "aws_lb_target_group" "london-tg" {
  name        = "london-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.london.id
  provider    = aws.london
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
    Name    = "london-tg"
    Service = "londonTG"
  }
}

# Listener
resource "aws_lb_listener" "london_http" {
  load_balancer_arn = aws_lb.london_alb.arn
  port              = 80
  protocol          = "HTTP"
  provider          = aws.london

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.london-tg.arn
  }
}

# Launch Template
resource "aws_launch_template" "london_LT" {
  provider      = aws.london
  name          = "london_LT"
  image_id      = data.aws_ami.al2023_london.id
  instance_type = "t2.micro"

  user_data = base64encode(templatefile("${path.module}/../scripts/1-user-data.sh", {
    loki_push_host = aws_lb.siem_nlb.dns_name
  }))

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.london_ec2_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "london-ec2-web-server"
    }
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "london_asg" {
  max_size            = 3
  min_size            = 2
  desired_capacity    = 2
  name                = "london-web-server-asg"
  target_group_arns   = [aws_lb_target_group.london-tg.id]
  vpc_zone_identifier = aws_subnet.private_subnet_london[*].id
  provider            = aws.london

  launch_template {
    id      = aws_launch_template.london_LT.id
    version = "$Latest"
  }

  health_check_type = "EC2"
}
/*
# TGW
resource "aws_ec2_transit_gateway" "london-TGW" {
  description = "london-TGW"
  provider    = aws.london

  tags = {
    Name     = "london-TGW"
    Service  = "TGW"
    Location = "london"
  }
}

# VPC Attachment
resource "aws_ec2_transit_gateway_vpc_attachment" "london-TGW-attachment" {
  subnet_ids         = aws_subnet.public_subnet_london[*].id
  transit_gateway_id = aws_ec2_transit_gateway.london-TGW.id
  vpc_id             = aws_vpc.london.id
  provider           = aws.london
}
*/