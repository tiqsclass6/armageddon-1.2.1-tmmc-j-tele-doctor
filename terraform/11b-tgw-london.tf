#############################################################
# TRANSIT GATEWAY - london
#############################################################
resource "aws_ec2_transit_gateway" "local_london" {
  provider                        = aws.london
  description                     = "london"
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  tags = {
    Name = "london TGW"
  }
}
#############################################################
# TRANSIT GATEWAY VPC ATTACHMENT
#############################################################
resource "aws_ec2_transit_gateway_vpc_attachment" "local_london_attachment" {
  provider           = aws.london
  subnet_ids         = aws_subnet.private_subnet_london[*].id
  transit_gateway_id = aws_ec2_transit_gateway.local_london.id
  vpc_id             = aws_vpc.london.id
  dns_support        = "enable"
  tags = {
    Name = "Attachment for tokyo"
  }
}
#############################################################
# TRANSIT GATEWAY PEERING ATTACHMENT
#############################################################
resource "aws_ec2_transit_gateway_peering_attachment" "hub_to_spoke_london" {
  transit_gateway_id      = aws_ec2_transit_gateway.local_london.id
  peer_transit_gateway_id = aws_ec2_transit_gateway.peer.id
  peer_region             = "ap-northeast-1"
  tags = {
    Name = "Hub to Spoke Peering new york"
  }
  provider = aws.london
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "spoke_accept_tko_london" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke_london.id
  provider                      = aws.tokyo
  tags = {
    Name = "Spoke Accept Hub Peering tokyo"
  }
}

#############################################################
# TRANSIT GATEWAY ROUTE TABLE CONFIGURATION
#############################################################
resource "aws_ec2_transit_gateway_route_table" "spoke_route_table_london" {
  transit_gateway_id = aws_ec2_transit_gateway.local_london.id
  tags = {
    Name = "Spoke TGW Route Table (london)"
  }
  provider = aws.london
}
#############################################################
# TRANSIT GATEWAY ROUTE TABLE ASSOCIATIONS
#############################################################
# Associate Spoke TGW Route Table with New York VPC Attachment
resource "aws_ec2_transit_gateway_route_table_association" "spoke_tgw_vpc_london" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.local_london_attachment.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_london.id
  provider                       = aws.london
}
# Associate Spoke TGW Route Table with New York perring Attachment
resource "aws_ec2_transit_gateway_route_table_association" "tgw_attachment_association_london" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke_london.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_london.id
  replace_existing_association   = true
  provider                       = aws.london

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_london]
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw_attachment_association_peer_london" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_london.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  replace_existing_association   = true
  provider                       = aws.tokyo

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_london]
}

resource "aws_ec2_transit_gateway_route" "hub_to_spoke_tko_london" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  destination_cidr_block         = aws_vpc.london.cidr_block
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_london.id
  provider                       = aws.tokyo

  depends_on = [aws_ec2_transit_gateway_route_table_association.tgw_attachment_association_peer_london]
}

resource "aws_ec2_transit_gateway_route" "spoke_to_hub_london" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_london.id
  destination_cidr_block         = local.syslog_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke_london.id
  provider                       = aws.london

  depends_on = [aws_ec2_transit_gateway_route_table_association.tgw_attachment_association_london]
}

resource "aws_ec2_transit_gateway_route" "spoke_to_spoke_vpc_london" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_london.id
  destination_cidr_block         = aws_vpc.london.cidr_block
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.local_london_attachment.id
  provider                       = aws.london
}

#############################################################
# VPC ROUTE TABLE CONFIGURATION
#############################################################
resource "aws_route" "siem_return_to_london" {
  route_table_id         = aws_route_table.tokyo_route_table_security_subnet.id
  destination_cidr_block = aws_vpc.london.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.peer.id
  provider               = aws.tokyo
}