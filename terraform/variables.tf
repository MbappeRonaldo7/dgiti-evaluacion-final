# ---------------------------------------------------------------------------
# variables.tf - Parámetros de la infraestructura
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "Región de AWS (el Learner Lab trabaja en us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para nombrar los recursos"
  type        = string
  default     = "dgiti"
}

variable "environment" {
  description = "Ambiente de despliegue"
  type        = string
  default     = "prod"
}

variable "owner" {
  description = "Responsable de la infraestructura (etiqueta Owner)"
  type        = string
  default     = "thomas-angulo"
}

# ----------------------------- Red ----------------------------------------
variable "vpc_cidr" {
  description = "Bloque CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Subredes públicas (ALB y NAT Gateway), una por AZ"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "Subredes privadas de aplicación (instancias EC2), una por AZ"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  description = "Subredes privadas de base de datos (sin salida a Internet), una por AZ"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

# ----------------------------- Cómputo ------------------------------------
variable "instance_type" {
  description = "Tipo de instancia EC2 para la aplicación"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Mínimo de instancias en el Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Instancias deseadas en el Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Máximo de instancias en el Auto Scaling Group"
  type        = number
  default     = 4
}

variable "cpu_target" {
  description = "Porcentaje de CPU promedio objetivo para el escalado automático"
  type        = number
  default     = 50
}

variable "instance_profile_name" {
  description = "Perfil de instancia existente (en Learner Lab no se pueden crear roles IAM)"
  type        = string
  default     = "LabInstanceProfile"
}

variable "app_port" {
  description = "Puerto en el que escucha la aplicación dentro de la instancia"
  type        = number
  default     = 8080
}

variable "app_version" {
  description = "Versión de la aplicación (el pipeline la reemplaza por el SHA del commit)"
  type        = string
  default     = "1.0.0"
}

# ----------------------------- Base de datos ------------------------------
variable "db_instance_class" {
  description = "Clase de instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Usuario administrador de la BD"
  type        = string
  default     = "appadmin"
}

variable "db_password" {
  description = "Contraseña de la BD. NUNCA en el repositorio: usar TF_VAR_db_password o un secreto de GitHub"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9]{8,41}$", var.db_password))
    error_message = "La contraseña de la BD debe tener entre 8 y 41 caracteres alfanuméricos."
  }
}
