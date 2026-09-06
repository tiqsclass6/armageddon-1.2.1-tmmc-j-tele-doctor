output "aurora_cluster_endpoint" {
  value       = aws_rds_cluster.aurora_cluster.endpoint
  description = "Aurora writer endpoint (Tokyo restricted AZs only)."
}

output "aurora_reader_endpoint" {
  value       = aws_rds_cluster.aurora_cluster.reader_endpoint
  description = "Aurora reader endpoint."
}

output "aurora_master_password" {
  value       = random_password.aurora_master.result
  description = "Aurora master password. Retrieve with terraform output -raw aurora_master_password."
  sensitive   = true
}

output "new_york_alb_dns" {
  value       = "http://${aws_lb.new_york_alb.dns_name}"
  description = "The DNS name of the New York load balancer."
}

output "london_alb_dns" {
  value       = "http://${aws_lb.london_alb.dns_name}"
  description = "The DNS name of the London load balancer."
}

output "sao_paulo_alb_dns" {
  value       = "http://${aws_lb.sao_paulo_alb.dns_name}"
  description = "The DNS name of the São Paulo load balancer."
}

output "sydney_alb_dns" {
  value       = "http://${aws_lb.sydney_alb.dns_name}"
  description = "The DNS name of the Sydney load balancer."
}

output "hong_kong_alb_dns" {
  value       = "http://${aws_lb.hong_kong_alb.dns_name}"
  description = "The DNS name of the Hong Kong load balancer."
}

output "california_alb_dns" {
  value       = "http://${aws_lb.california_alb.dns_name}"
  description = "The DNS name of the California load balancer."
}

output "tokyo_alb_dns" {
  value       = "http://${aws_lb.tokyo_alb.dns_name}"
  description = "The DNS name of the Tokyo load balancer."
}

######################################################################
# V1.2 A.3 / A.4 — artifacts proving spokes are send-only to syslog
######################################################################

output "a3_syslog_cidr_spokes_may_reach" {
  description = "Only this Tokyo prefix is routed from spokes. App and DB subnets are excluded."
  value       = local.syslog_cidr
}

output "a3_siem_subnet_cidrs" {
  description = "SIEM subnets (restricted AZs, no public subnets, not shared with DB)."
  value       = aws_subnet.siem_subnet_tokyo[*].cidr_block
}

output "a3_db_subnet_cidrs" {
  description = "PII DB subnets. Spokes have no TGW route here."
  value       = aws_subnet.db_subnet_tokyo[*].cidr_block
}

output "a3_restricted_azs_have_no_public_subnet" {
  description = "AZs that contain syslog and PII. Public subnets exist only in vpc_az_tokyo."
  value = {
    restricted_azs_syslog_and_pii = var.vpc_az_tokyo_restricted
    app_azs_with_public_subnets   = var.vpc_az_tokyo
  }
}

output "a3_loki_ingest_nlb" {
  description = "Internal NLB spokes may send Loki to (TCP 3100). Not a Grafana endpoint."
  value = {
    dns_name = aws_lb.siem_nlb.dns_name
    port     = local.loki_ingest_port
    internal = aws_lb.siem_nlb.internal
  }
}

output "a3_grafana_internal_alb" {
  description = "Grafana ALB. Security group allows Tokyo VPC only; spokes are not in that CIDR."
  value = {
    dns_name                      = aws_lb.siem_grafana_alb.dns_name
    port                          = local.grafana_port
    allowed_ingress_cidr          = aws_vpc.tokyo.cidr_block
    spoke_cidrs_explicitly_denied = local.spoke_cidrs
  }
}

output "a3_siem_nlb_sg_ingress" {
  description = "NLB SG: Loki 3100 from spoke CIDRs and Tokyo. No Grafana/SSH."
  value = [
    for r in aws_security_group.siem_nlb_sg.ingress : {
      from_port   = r.from_port
      to_port     = r.to_port
      protocol    = r.protocol
      cidr_blocks = r.cidr_blocks
      description = r.description
    }
  ]
}

output "a3_grafana_alb_sg_ingress" {
  description = "Grafana ALB SG: port 3000 from Tokyo VPC CIDR only."
  value = [
    for r in aws_security_group.siem_grafana_alb_sg.ingress : {
      from_port   = r.from_port
      to_port     = r.to_port
      protocol    = r.protocol
      cidr_blocks = r.cidr_blocks
      description = r.description
    }
  ]
}

output "a3_spoke_tgw_routes_to_syslog_only" {
  description = "Each spoke TGW route table destination toward Japan. Must be syslog CIDR, not 10.230.0.0/16."
  value = {
    new_york   = aws_ec2_transit_gateway_route.spoke_to_hub.destination_cidr_block
    london     = aws_ec2_transit_gateway_route.spoke_to_hub_london.destination_cidr_block
    sao_paulo  = aws_ec2_transit_gateway_route.spoke_to_hub_sao_paulo.destination_cidr_block
    sydney     = aws_ec2_transit_gateway_route.spoke_to_hub_sydney.destination_cidr_block
    hong_kong  = aws_ec2_transit_gateway_route.spoke_to_hub_hong_kong.destination_cidr_block
    california = aws_ec2_transit_gateway_route.spoke_to_hub_california.destination_cidr_block
  }
}

output "a3_aurora_ingress_sources" {
  description = "PII database accepts 5432 only from the Tokyo web ASG security group, not from spokes."
  value = {
    port                     = 5432
    source_security_group_id = aws_security_group.tokyo_ec2_sg.id
    region                   = "ap-northeast-1"
    no_vpn                   = true
  }
}

output "a3_siem_nacl_id" {
  description = "NACL on SIEM subnets denying Grafana 3000 and SSH 22 from the internet/spokes after Tokyo-only allow."
  value       = aws_network_acl.siem.id
}
