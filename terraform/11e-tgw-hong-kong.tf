variable "regions_HK" {
  default = ["hong_kong"]
}

variable "hub_region_HK" {
  default = "tokyo"
}

#############################################################
# TRANSIT GATEWAY - hong_kong
#############################################################
resource "aws_ec2_transit_gateway" "local_hong_kong" {
  provider                        = aws.hong_kong
  description                     = "hong_kong"
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  tags = {
    Name = "hong_kong TGW"
  }
}
#############################################################
# TRANSIT GATEWAY VPC ATTACHMENT
#############################################################
resource "aws_ec2_transit_gateway_vpc_attachment" "local_hong_kong_attachment" {
  provider           = aws.hong_kong
  subnet_ids         = aws_subnet.private_subnet_hong_kong[*].id
  transit_gateway_id = aws_ec2_transit_gateway.local_hong_kong.id
  vpc_id             = aws_vpc.hong_kong.id
  dns_support        = "enable"
  tags = {
    Name = "Attachment for hong_kong"
  }
}
#############################################################
# TRANSIT GATEWAY PEERING ATTACHMENT
#############################################################
resource "aws_ec2_transit_gateway_peering_attachment" "hub_to_spoke_hong_kong" {
  transit_gateway_id      = aws_ec2_transit_gateway.local_hong_kong.id
  peer_transit_gateway_id = aws_ec2_transit_gateway.peer.id
  peer_region             = "ap-northeast-1"
  tags = {
    Name = "Hub to Spoke Peering Hong Kong"
  }
  provider = aws.hong_kong
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "spoke_accept_tko_hong_kong" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke_hong_kong.id
  provider                      = aws.tokyo
  tags = {
    Name = "Spoke Accept Hub Peering tokyo"
  }
}

#############################################################
# TRANSIT GATEWAY ROUTE TABLE CONFIGURATION
#############################################################
resource "aws_ec2_transit_gateway_route_table" "spoke_route_table_hong_kong" {
  transit_gateway_id = aws_ec2_transit_gateway.local_hong_kong.id
  tags = {
    Name = "Spoke TGW Route Table (hong_kong)"
  }
  provider = aws.hong_kong
}
#############################################################
# TRANSIT GATEWAY ROUTE TABLE ASSOCIATIONS
#############################################################
# Associate Spoke TGW Route Table with New York VPC Attachment
resource "aws_ec2_transit_gateway_route_table_association" "spoke_tgw_vpc_hong_kong" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.local_hong_kong_attachment.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_hong_kong.id
  provider                       = aws.hong_kong
}
# Associate Spoke TGW Route Table with New York perring Attachment
resource "aws_ec2_transit_gateway_route_table_association" "tgw_attachment_association_hong_kong" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke_hong_kong.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_hong_kong.id
  replace_existing_association   = true
  provider                       = aws.hong_kong

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_hong_kong]
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw_attachment_association_peer_hong_kong" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_hong_kong.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  replace_existing_association   = true
  provider                       = aws.tokyo

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_hong_kong]
}

resource "aws_ec2_transit_gateway_route" "hub_to_spoke_tko_hong_kong" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub_route_table.id
  destination_cidr_block         = aws_vpc.hong_kong.cidr_block
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.spoke_accept_tko_hong_kong.id
  provider                       = aws.tokyo

  depends_on = [aws_ec2_transit_gateway_route_table_association.tgw_attachment_association_peer_hong_kong]
}

resource "aws_ec2_transit_gateway_route" "spoke_to_hub_hong_kong" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_hong_kong.id
  destination_cidr_block         = local.syslog_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub_to_spoke_hong_kong.id
  provider                       = aws.hong_kong

  depends_on = [aws_ec2_transit_gateway_route_table_association.tgw_attachment_association_hong_kong]
}

resource "aws_ec2_transit_gateway_route" "spoke_to_spoke_vpc_hong_kong" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_route_table_hong_kong.id
  destination_cidr_block         = aws_vpc.hong_kong.cidr_block
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.local_hong_kong_attachment.id
  provider                       = aws.hong_kong
}

#############################################################
# VPC ROUTE TABLE CONFIGURATION
#############################################################
resource "aws_route" "siem_return_to_hong_kong" {
  route_table_id         = aws_route_table.tokyo_route_table_security_subnet.id
  destination_cidr_block = aws_vpc.hong_kong.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.peer.id
  provider               = aws.tokyo
}