# terraform/oci/network.tf
#
# Internet gateway and default route for the VCN.
# If these already exist from the OCI console wizard, import them:
#   terraform import oci_core_internet_gateway.igw "IGW_OCID"
#   terraform import oci_core_route_table.rt "ROUTE_TABLE_OCID"

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  enabled        = true
  display_name   = "nixos-igw"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  display_name   = "Default Route Table for nixos-vcn"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}
