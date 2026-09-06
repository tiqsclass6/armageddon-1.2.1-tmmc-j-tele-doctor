########################################################
# Availability Zones
########################################################

variable "vpc_az_new_york" {
  type        = list(string)
  description = "Availability Zone"
  default     = ["us-east-1a", "us-east-1c"]
}

variable "vpc_az_london" {
  type        = list(string)
  description = "Availability Zone"
  default     = ["eu-west-2a", "eu-west-2c"]
}

variable "vpc_az_sao_paulo" {
  type        = list(string)
  description = "Availability Zone"
  default     = ["sa-east-1a", "sa-east-1c"]
}

variable "vpc_az_australia" {
  type        = list(string)
  description = "Availability Zone"
  default     = ["ap-southeast-2a", "ap-southeast-2c"]
}

variable "vpc_az_hong_kong" {
  type        = list(string)
  description = "Availability Zone"
  default     = ["ap-east-1a", "ap-east-1c"]
}

variable "vpc_az_california" {
  type        = list(string)
  description = "Availability Zone"
  default     = ["us-west-1a", "us-west-1c"]
}

variable "vpc_az_tokyo" {
  type        = list(string)
  description = "App AZs (public + private). Do not place syslog or PII here."
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

# This account's Tokyo AZs are 1a, 1c, 1d only (no 1b).
# App public subnets stay on 1a/1c. Restricted subnets use 1d + 1c so NLB/Aurora
# still span two AZs. 1d has no public subnet; 1c also has app public subnets.
variable "vpc_az_tokyo_restricted" {
  type        = list(string)
  description = "AZs for SIEM and Aurora. Prefer AZs with no public subnet when the account has them."
  default     = ["ap-northeast-1d", "ap-northeast-1c"]
}

locals {
  # SIEM subnets are 10.230.60.0/24 and 10.230.61.0/24.
  # Spokes may route only here — not to app or DB subnets.
  syslog_cidr = "10.230.60.0/23"

  loki_ingest_port = 3100
  grafana_port     = 3000

  spoke_cidrs = [
    "10.231.0.0/16", # New York
    "10.232.0.0/16", # London
    "10.233.0.0/16", # Sao Paulo
    "10.234.0.0/16", # Sydney
    "10.235.0.0/16", # Hong Kong
    "10.236.0.0/16", # California
  ]
}

##########################################################
# Regions for TGW
##########################################################

variable "regions" {
  default = ["new_york"]
}

variable "regions_UK" {
  default = ["london"]
}

variable "regions_BR" {
  default = ["sao_paulo"]
}

variable "regions_AUS" {
  default = ["sydney"]
}

variable "regions_CA" {
  default = ["california"]
}

##########################################################
# Hub Region for TGW (Tokyo)
##########################################################

variable "hub_region" {
  default = "tokyo"
}

variable "hub_region_UK" {
  default = "tokyo"
}

variable "hub_region_BR" {
  default = "tokyo"
}

variable "hub_region_AUS" {
  default = "tokyo"
}

variable "hub_region_CA" {
  default = "tokyo"
}