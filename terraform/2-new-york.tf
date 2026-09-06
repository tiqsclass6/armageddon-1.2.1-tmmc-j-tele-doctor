#################################
# VPC
################################

resource "aws_vpc" "new_york" {
  cidr_block           = "10.231.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  provider             = aws.new_york
  tags = {
    Name = "New York VPC"
  }
}

#################################
# Public Subnets
#################################

resource "aws_subnet" "public_subnet_new_york" {
  vpc_id            = aws_vpc.new_york.id
  count             = length(var.vpc_az_new_york)
  cidr_block        = cidrsubnet(aws_vpc.new_york.cidr_block, 8, count.index + 1)
  availability_zone = element(var.vpc_az_new_york, count.index)
  provider          = aws.new_york
  tags = {
    Name = "New York Public Subnet${count.index + 1}",
  }
}

#################################
# Private Subnets
#################################

resource "aws_subnet" "private_subnet_new_york" {
  vpc_id            = aws_vpc.new_york.id
  count             = length(var.vpc_az_new_york)
  cidr_block        = cidrsubnet(aws_vpc.new_york.cidr_block, 8, count.index + 11)
  availability_zone = element(var.vpc_az_new_york, count.index)
  provider          = aws.new_york
  tags = {
    Name = "New York Private Subnet${count.index + 1}",
  }
}


#################################
# Internet Gateway
#################################

resource "aws_internet_gateway" "new_york_igw" {
  vpc_id   = aws_vpc.new_york.id
  provider = aws.new_york

  tags = {
    Name = "new_york_igw"
  }
}

#################################
# Route Table for Public Subnet
#################################

resource "aws_route_table" "new_york_route_table_public_subnet" {
  vpc_id   = aws_vpc.new_york.id
  provider = aws.new_york

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.new_york_igw.id
  }

  tags = {
    Name = "Route Table for Public Subnet",
  }

}

##########################################################
# Route Table Association Public and Internet Gateway
###########################################################

resource "aws_route_table_association" "new_york_public_subnet_association" {
  route_table_id = aws_route_table.new_york_route_table_public_subnet.id
  count          = length((var.vpc_az_new_york))
  subnet_id      = element(aws_subnet.public_subnet_new_york[*].id, count.index)
  provider       = aws.new_york
}


#################################
# EIP for NAT Gateway
#################################

resource "aws_eip" "new_york_eip" {
  domain   = "vpc"
  provider = aws.new_york
}


#################################
# NAT Gateway
#################################

resource "aws_nat_gateway" "new_york_nat" {
  allocation_id = aws_eip.new_york_eip.id
  subnet_id     = aws_subnet.public_subnet_new_york[0].id
  provider      = aws.new_york
}

#################################
# Route Table for Private Subnet
#################################

resource "aws_route_table" "new_york_route_table_private_subnet" {
  vpc_id   = aws_vpc.new_york.id
  provider = aws.new_york

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.new_york_nat.id
  }

  route {
    cidr_block         = local.syslog_cidr
    transit_gateway_id = aws_ec2_transit_gateway.local_new_york.id
  }

  tags = {
    Name = "Route Table for Private Subnet",
  }

}

#################################
# Route Table Association Private
#################################
resource "aws_route_table_association" "new_york_private_subnet_association" {
  route_table_id = aws_route_table.new_york_route_table_private_subnet.id
  count          = length((var.vpc_az_new_york))
  subnet_id      = element(aws_subnet.private_subnet_new_york[*].id, count.index)
  provider       = aws.new_york
}

##########################################################
# Application Load Balancer Security Group
###########################################################

resource "aws_security_group" "new_york_alb_sg" {
  name        = "new_york-alb-sg"
  description = "Security Group for Application Load Balancer"
  provider    = aws.new_york

  vpc_id = aws_vpc.new_york.id

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
    Name = "new_york-alb-sg"
  }
}

##########################################################
# EC2 Security Group
###########################################################

resource "aws_security_group" "new_york_sg" {
  name        = "new_york-ec2-sg"
  description = "Security Group for Webserver Instance"
  provider    = aws.new_york

  vpc_id = aws_vpc.new_york.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "TCP"
    security_groups = [aws_security_group.new_york_alb_sg.id]

  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "new_york-ec2-sg"
  }
}

##########################################################
# Load Balancer
###########################################################
resource "aws_lb" "new_york_alb" {
  name                       = "new-york-load-balancer"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public_subnet_new_york[*].id
  security_groups            = [aws_security_group.new_york_alb_sg.id]
  depends_on                 = [aws_internet_gateway.new_york_igw]
  enable_deletion_protection = false
  provider                   = aws.new_york

  tags = {
    Name    = "new_yorkLoadBalancer"
    Service = "new_york"
  }
}

##########################################################
# Target Group
##########################################################

resource "aws_lb_target_group" "new_york_tg" {
  name        = "new-york-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.new_york.id
  provider    = aws.new_york
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
    Name = "new_york_tg"
  }
}

##########################################################
# Listener
##########################################################

resource "aws_lb_listener" "new_york_http" {
  load_balancer_arn = aws_lb.new_york_alb.arn
  port              = 80
  protocol          = "HTTP"
  provider          = aws.new_york

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.new_york_tg.arn
  }
}


##########################################################
# Launch Template
##########################################################
resource "aws_launch_template" "new_york_LT" {
  provider      = aws.new_york
  name          = "new_york_LT"
  image_id      = data.aws_ami.al2023_new_york.id
  instance_type = "t2.micro"

  user_data = base64encode(templatefile("${path.module}/../scripts/1-user-data.sh", {
    loki_push_host = aws_lb.siem_nlb.dns_name
  }))

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.new_york_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "new_york-ec2-web-server"
    }
  }
}

##########################################################
# Auto Scaling Group
##########################################################

resource "aws_autoscaling_group" "new_york_asg" {
  max_size            = 3
  min_size            = 2
  desired_capacity    = 2
  name                = "new_york-web-server-asg"
  target_group_arns   = [aws_lb_target_group.new_york_tg.arn]
  vpc_zone_identifier = aws_subnet.private_subnet_new_york[*].id
  provider            = aws.new_york

  launch_template {
    id      = aws_launch_template.new_york_LT.id
    version = "$Latest"
  }

  health_check_type = "EC2"
}