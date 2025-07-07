provider "aws" {
    region = "eu-west-2" 
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "main.vpc"
  }
}

resource "aws_subnet" "public_subnet" {
    vpc_id                  = aws_vpc.main.id
    cidr_block              = "10.0.0.0/24"
    availability_zone       = "eu-west-2a"
    map_public_ip_on_launch = true

    tags = {
      Name = "public-subnet"
    }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-west-2b"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-2"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
    }
}

resource "aws_route_table_association" "public_subnet_association" {
    subnet_id      = aws_subnet.public_subnet.id
    route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_subnet_assoc_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2_sg" {
    name        = "ec2-sg"
    description = "Allow HTTP from ALB"
    vpc_id      = aws_vpc.main.id

    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        security_groups = [ aws_security_group.alb_sg.id ]
        description     = "Allow HTTP from ALB"
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [ "0.0.0.0/0" ]
    }

    tags = {
        Name = "ec2_sg"
    }
}

resource "aws_security_group" "alb_sg" {
    name = "alb-sg"
    description = "Allow HTTP from anywhere"
    vpc_id = aws_vpc.main.id

    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = [ "0.0.0.0/0" ]
        description = "Allow HTTP"
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [ "0.0.0.0/0" ]
    }

    tags = {
      Name = "alb-sg"
    }
}

resource "aws_launch_template" "web_template" {
    name_prefix   = "web_template"
    image_id      = "ami-00f7e79ebcafba5e4" # Amazon Linux 2
    instance_type = "t2.micro"

    vpc_security_group_ids = [ aws_security_group.ec2_sg.id ]

    user_data = base64encode(<<-E0F
        #!/bin/bash
        sudo yum update -y
        sudo yum install -y httpd
        systemctl enable httpd
        systemctl start httpd
        echo "<h1>Hello from Terraform EC2</h1>" > /var/www/html/index.html
        E0F
    )

    tag_specifications {
      resource_type = "instance"

      tags = {
        Name = "web-server"
      }
    }
}

resource "aws_autoscaling_group" "web_asg" {
    vpc_zone_identifier = [ aws_subnet.public_subnet.id ]
    desired_capacity    = 2
    max_size            = 3
    min_size            = 1
    launch_template {
      id      = aws_launch_template.web_template.id
      version = "$Latest"
    }

    tag {
      key                 = "Name"
      value               = "web-asg-instance"
      propagate_at_launch = true
    }

    target_group_arns = [ aws_lb_target_group.web_tg.arn ]

    health_check_type         = "EC2"
    health_check_grace_period = 300

    depends_on = [ aws_lb_target_group.web_tg ]
}

resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [
    aws_subnet.public_subnet.id,
    aws_subnet.public_subnet_2.id
    ]

  tags = {
    Name = "web-alb"
  }
}

resource "aws_lb_target_group" "web_tg" {
    name     = "web-tg"
    port     = 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.main.id

    health_check {
      path                = "/"
      protocol            = "HTTP"
      matcher             = "200"
      interval            = 30
      timeout             = 5
      healthy_threshold   = 2
      unhealthy_threshold = 2
    }
}

resource "aws_alb_listener" "web_listener" {
    load_balancer_arn = aws_lb.web_alb.arn
    port              = "80"
    protocol          = "HTTP"

    default_action {
      type             = "forward"
      target_group_arn = aws_lb_target_group.web_tg.arn
    }
}