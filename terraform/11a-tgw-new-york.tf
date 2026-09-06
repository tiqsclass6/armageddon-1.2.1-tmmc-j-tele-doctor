#############################################################
# TRANSIT GATEWAY
#############################################################
resource "aws_ec2_transit_gateway" "local_new_york" {
  provider                        = aws.new_york
  description                     = "new_york"
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  tags = {
    Name = "new_york TGW"
  }
}

//Remove when not testing
resource "aws_ec2_transit_gateway" "peer" {
  provider                        = aws.tokyo
  description                     = "tokyo"
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  tags = {
    Name = "tokyo TGW"
  }
}

#############################################################
# TRANSIT GATEWAY VPC ATTACHMENT
#############################################################
resource "aws_ec2_transit_gateway_vpc_attachment" "local_new_york_attachment" {
  provider           = aws.new_york
  subnet_ids         = aws_subnet.private_subnet_new_york[*].id
  transit_gateway_id = aws_ec2_transit_gateway.local_new_york.id
  vpc_id             = aws_vpc.new_york.id
  dns_support        = "enable"
  tags = {
    Name = "Attachment for tokyo"
  }
}

//Remove when not testing
resource "aws_ec2_transit_gateway_vpc_attachment" "peer_attachment" {
  provider = aws.tokyo

  subnet_ids         = aws_subnet.private_subnet_tokyo[*].id
  transit_gateway_id = aws_ec2_transit_gateway.peer.id
  vpc_id             = aws_vpc.tokyo.id
  dns_support        = "enable"
  tags = {
    Name = "Attachment for tokyo"
  }
}

#############################################################
# TRANSIT GATEWAY PEERING ATTACHMENT
#############################################################
resource "aws_ec2_transit_gateway_peering_attachment" "hub_to_spoke" {

  transit_gateway_id      = aws_ec2_transit_gateway.local_new_york.id # Hub TGW
  peer_transit_gateway_id = aws_ec2_transit_gateway.peer.id           # Spoke TGWs

  peer_region = "ap-northeast-1"

  tags = {
    Name = "Hub to Spoke Peering new york"
  }

  provider = aws.new_york # Hub TGW provider
}

#############################################################
# TRANSIT GATEWAY PEERING ACCEPTER
#############################################################
resource "aws_ec2_transit_gateway_peering_attachment_accepter" "spoke_accept" {


  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke.id
  provider                      = aws.tokyo
  tags = {
    Name = "Spoke Accept Hub Peering tokyo"
  }
}

#############################################################
# TRANSIT GATEWAY ROUTE TABLE
#############################################################

resource "aws_ec2_transit_gateway_route_table" "hub_route_table" {
  transit_gateway_id = aws_ec2_transit_gateway.peer.id
  tags = {
    Name = "Hub TGW Route Table (Tokyo)"
  }
  provider = aws.tokyo
}

resource "aws_ec2_transit_gateway_route_table" "spoke_route_table" {
  transit_gateway_id = aws_ec2_transit_gateway.local_new_york.id

  tags = {
    Name = "Spoke TGW Route Table (New York)"
  }
  provider = aws.new_york
}

#############################################################
# TRANSIT GATEWAY ROUTE TABLE ASSOCIATIONS HUB
#############################################################

# Associate Hub TGW Route Table with Tokyo VPC Attachment
resource "aws_ec2_transit_gateway_route_table_association" "hub_tgw_vpc" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.peer_attachment.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  provider                       = aws.tokyo
}

# Associate Hub TGW Route Table with Tokyo Peering Attachment
resource "aws_ec2_transit_gateway_route_table_association" "tgw_attachment_association_peer" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  replace_existing_association   = true
  provider                       = aws.tokyo
}

#############################################################
# TRANSIT GATEWAY ROUTE TABLE ASSOCIATIONS NEW YORK
#############################################################

# Associate Spoke TGW Route Table with New York VPC Attachment
resource "aws_ec2_transit_gateway_route_table_association" "spoke_tgw_vpc" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.local_new_york_attachment.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table.id
  provider                       = aws.new_york
}

# Associate Spoke TGW Route Table with New York peering attachment
resource "aws_ec2_transit_gateway_route_table_association" "tgw_attachment_association" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table.id
  replace_existing_association   = true
  provider                       = aws.new_york

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept]
}

#############################################################
# TRANSIT GATEWAY ROUTES
#############################################################

# Route from Hub TGW to Spoke VPC (Tokyo -> New York)
resource "aws_ec2_transit_gateway_route" "hub_to_spoke" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  destination_cidr_block         = aws_vpc.new_york.cidr_block # New York VPC CIDR
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept.id
  provider                       = aws.tokyo

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.local_new_york_attachment,
    aws_ec2_transit_gateway_route_table_association.tgw_attachment_association_peer,
  ]
}

# Route from Hub TGW to Tokyo VPC (Tokyo -> Tokyo VPC CIDR)
resource "aws_ec2_transit_gateway_route" "hub_to_hub_vpc" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  destination_cidr_block         = aws_vpc.tokyo.cidr_block # tokyo VPC CIDR
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.peer_attachment.id
  provider                       = aws.tokyo
}

# Route from Spoke TGW to Hub syslog CIDR only (A.3 / PII isolation)
resource "aws_ec2_transit_gateway_route" "spoke_to_hub" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table.id
  destination_cidr_block         = local.syslog_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke.id
  provider                       = aws.new_york

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept,
    aws_ec2_transit_gateway_route_table_association.tgw_attachment_association,
  ]
}

# Route from Spoke TGW to New York VPC (New York -> New York VPC CIDR)
resource "aws_ec2_transit_gateway_route" "spoke_to_spoke_vpc" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table.id
  destination_cidr_block         = aws_vpc.new_york.cidr_block # New York VPC CIDR
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.local_new_york_attachment.id
  provider                       = aws.new_york
}
#############################################################
# VPC ROUTE TABLE CONFIGURATION
#############################################################

# Return path: SIEM subnets -> New York (syslog ACK). Not on app private RT.
resource "aws_route" "siem_return_to_new_york" {
  route_table_id         = aws_route_table.tokyo_route_table_security_subnet.id
  destination_cidr_block = aws_vpc.new_york.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.peer.id
  provider               = aws.tokyo
}