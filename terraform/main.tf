# ===========================================================================
# main.tf - Infraestructura de la evaluación final DGITI
#
#  Internet -> ALB (subredes públicas, 2 AZ)
#           -> Auto Scaling Group de EC2 (subredes privadas de app, 2 AZ)
#           -> RDS MySQL primaria + Read Replica (subredes privadas de BD, 2 AZ)
#  Security Groups encadenados: ALB -> App -> BD
# ===========================================================================

locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Amazon Linux 2023 más reciente
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ===========================================================================
# 1. RED: VPC, subredes, Internet Gateway, NAT Gateway y tablas de rutas
# ===========================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-app-${local.azs[count.index]}", Tier = "private-app" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-db-${local.azs[count.index]}", Tier = "private-db" }
}

# NAT Gateway: las instancias privadas salen a Internet (instalar paquetes)
# sin ser accesibles desde Internet. Se usa uno solo para ahorrar créditos.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = { Name = "${local.name}-rt-app" }
}

# La capa de BD no tiene ruta a Internet: solo tráfico local de la VPC
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-db" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# ===========================================================================
# 2. SEGURIDAD: Security Groups encadenados (mínimo privilegio)
# ===========================================================================
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB: HTTP desde Internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Hacia las instancias de la app"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "App: solo recibe trafico del ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Trafico de la app solo desde el ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Salida (paquetes via NAT y conexion a RDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "BD: MySQL solo desde las instancias de la app"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL solo desde el SG de la app"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # Sin reglas de salida: la BD no inicia conexiones.
  tags = { Name = "${local.name}-db-sg" }
}

# ===========================================================================
# 3. ALMACENAMIENTO: bucket S3 para los logs de acceso del ALB
# ===========================================================================
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  count         = var.enable_alb_logs ? 1 : 0
  bucket        = "${local.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${local.name}-alb-logs" }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count                   = var.enable_alb_logs ? 1 : 0
  bucket                  = aws_s3_bucket.alb_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "alb_logs" {
  count  = var.enable_alb_logs ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Sid       = "AllowELBLogDelivery"
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs[0].arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    }]
  })
}

# ===========================================================================
# 4. BALANCEADOR DE CARGA (Application Load Balancer)
# ===========================================================================
resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  dynamic "access_logs" {
    for_each = var.enable_alb_logs ? [1] : []
    content {
      bucket  = aws_s3_bucket.alb_logs[0].id
      prefix  = "alb"
      enabled = true
    }
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
  tags       = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name}-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ===========================================================================
# 5. BASE DE DATOS: RDS MySQL primaria + Read Replica en otra AZ
# ===========================================================================
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${local.name}-db-subnets" }
}

resource "aws_db_instance" "primary" {
  identifier              = "${local.name}-db-primary"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  availability_zone       = local.azs[0]
  publicly_accessible     = false
  backup_retention_period = 1 # requerido para poder crear la réplica
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = { Name = "${local.name}-db-primary", Role = "primary" }
}

resource "aws_db_instance" "replica" {
  identifier             = "${local.name}-db-replica"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.db_instance_class
  storage_type           = "gp3"
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = local.azs[1]
  publicly_accessible    = false
  skip_final_snapshot    = true
  apply_immediately      = true

  tags = { Name = "${local.name}-db-replica", Role = "read-replica" }
}

# ===========================================================================
# 6. CÓMPUTO: Launch Template + Auto Scaling Group en 2 AZ
# ===========================================================================
resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  monitoring {
    enabled = true # métricas de EC2 cada 1 minuto en CloudWatch
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 obligatorio
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    app_py_b64       = filebase64("${path.module}/../app/app.py")
    requirements_b64 = filebase64("${path.module}/../app/requirements.txt")
    app_version      = var.app_version
    app_port         = var.app_port
    db_host          = aws_db_instance.primary.address
    db_replica_host  = aws_db_instance.replica.address
    db_name          = var.db_name
    db_user          = var.db_username
    db_password      = var.db_password
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-app" }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-asg"
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_capacity
  max_size                  = var.asg_max_size
  vpc_zone_identifier       = aws_subnet.app[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  enabled_metrics = [
    "GroupInServiceInstances",
    "GroupDesiredCapacity",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Cada cambio en el Launch Template (nueva versión de la app) reemplaza
  # las instancias de forma gradual, manteniendo al menos el 50 % en servicio.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-app"
    propagate_at_launch = true
  }
}

# Escalado automático: mantiene la CPU promedio cerca del objetivo
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}

# ===========================================================================
# 7. MONITOREO: alarmas y dashboard de CloudWatch
# ===========================================================================
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "Alguna instancia detrás del ALB no pasa el health check"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-target-5xx"
  alarm_description   = "Errores 5XX de las instancias por encima de 10 por minuto"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-dashboard"

  dashboard_body = templatefile("${path.module}/dashboard.json.tftpl", {
    region     = var.aws_region
    alb        = aws_lb.app.arn_suffix
    tg         = aws_lb_target_group.app.arn_suffix
    asg        = aws_autoscaling_group.app.name
    az1        = local.azs[0]
    az2        = local.azs[1]
    db_primary = aws_db_instance.primary.identifier
    db_replica = aws_db_instance.replica.identifier
  })
}
