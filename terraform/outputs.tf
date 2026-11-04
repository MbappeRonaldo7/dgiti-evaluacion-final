# ---------------------------------------------------------------------------
# outputs.tf - Valores útiles después del apply
# ---------------------------------------------------------------------------
output "alb_dns_name" {
  description = "DNS público del Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "app_url" {
  description = "URL del servicio"
  value       = "http://${aws_lb.app.dns_name}"
}

output "health_url" {
  description = "Endpoint de validación"
  value       = "http://${aws_lb.app.dns_name}/health"
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "security_groups" {
  description = "IDs de los Security Groups (ALB -> App -> BD)"

  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "db_primary_endpoint" {
  description = "Endpoint privado de la BD primaria (no accesible desde Internet)"
  value       = aws_db_instance.primary.address
}

output "db_replica_endpoint" {
  description = "Endpoint privado de la réplica de lectura"
  value       = aws_db_instance.replica.address
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
