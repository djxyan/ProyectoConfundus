terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}


resource "aws_vpc" "confundus-vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "confundus-vpc"
  }
}


resource "aws_subnet" "confundus-subnet" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.confundus-vpc.id
  cidr_block        = element(var.public_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Confundus Subnet ${count.index + 1}"
  }
}

resource "aws_internet_gateway" "confundus-igw" {
  vpc_id = aws_vpc.confundus-vpc.id

  tags = {
    Name = "confundus-igw"
  }
}

resource "aws_route_table" "confundus-rt" {
  vpc_id = aws_vpc.confundus-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.confundus-igw.id
  }

  tags = {
    Name = "confundus-rt"
  }
}

resource "aws_route_table_association" "public_subnet_asso" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = element(aws_subnet.confundus-subnet[*].id, count.index)
  route_table_id = aws_route_table.confundus-rt.id
}

resource "aws_security_group" "confundus-sg" {
  name   = "confundus-sg"
  vpc_id = aws_vpc.confundus-vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    self        = "false"
    cidr_blocks = ["0.0.0.0/0"]
    description = "any"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "confundus-sg"
  }
}

resource "aws_ecs_cluster" "confundus-ecs-cluster" {
  name = "confundus-ecs-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "confundus-cluster-provider" {
  cluster_name = aws_ecs_cluster.confundus-ecs-cluster.name

  capacity_providers = ["FARGATE_SPOT", "FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
  }
}

resource "aws_ecs_task_definition" "confundus-task" {
  family                   = "confundus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE", "EC2"]
  cpu                      = 256
  memory                   = 512

  container_definitions = jsonencode([
    {
      name : "nginx",
      image : "nginx:latest",
      essential : true,
      portMappings : [
        {
          containerPort : 80,
          hostPort : 80,
        },
      ],
    },
  ])

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_lb" "confundus-lb" {
  name            = "confundus-lb"
  subnets         = aws_subnet.confundus-subnet.*.id
  security_groups = [aws_security_group.confundus-sg.id]
}

resource "aws_lb_target_group" "confundus-tg" {
  name        = "confundus-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.confundus-vpc.id
  target_type = "ip"
}

resource "aws_lb_listener" "confundus-listener" {
  load_balancer_arn = aws_lb.confundus-lb.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.confundus-tg.id
    type             = "forward"
  }
}

resource "aws_ecs_service" "confundus-service" {
  name             = "confundus-service"
  cluster          = aws_ecs_cluster.confundus-ecs-cluster.id
  task_definition  = aws_ecs_task_definition.confundus-task.arn
  desired_count    = 2
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  load_balancer {
    target_group_arn = aws_lb_target_group.confundus-tg.arn
    container_name   = "nginx"
    container_port   = 80
  }

  network_configuration {
    assign_public_ip = true
    subnets          = aws_subnet.confundus-subnet.*.id
  }

}

resource "aws_s3_bucket" "confundus-bucket" {
  bucket = "confundus-bucket"

  tags = {
    Name = "confundus-bucket"
  }
}

resource "aws_s3_bucket_object" "confundus-bucket-obj" {
  bucket = aws_s3_bucket.confundus-bucket.id
  key    = "index.html"
  source = "./web-component/index.html"
  etag   = filemd5("./web-component/index.html")
  content_type = "text/html"
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.confundus-bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.s3_origin_access_identity.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "confundus-policy" {
  bucket = aws_s3_bucket.confundus-bucket.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

// CloudFront origin access identity to associate with the distribution
resource "aws_cloudfront_origin_access_identity" "s3_origin_access_identity" {
  comment = "S3 OAI for the Cloudfront Distribution"
}

// CloudFront Distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.confundus-bucket.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.confundus-bucket.id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.s3_origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Confundus S3 bucket"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.confundus-bucket.id

    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    viewer_protocol_policy = "allow-all"

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations = []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "cloudfront_domain_name" {
  description = "The domain name corresponding to the distribution"
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}