# terraform/oci/variables.tf

variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID"
  type        = string
}

variable "compartment_ocid" {
  description = "OCI compartment OCID"
  type        = string
}

variable "region" {
  description = "OCI region (e.g. uk-london-1)"
  type        = string
}

variable "namespace" {
  description = "Object Storage namespace"
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint"
  type        = string
}

variable "private_key_path" {
  description = "Path to OCI API private key"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "vcn_ocid" {
  description = "VCN OCID"
  type        = string
}

variable "subnet_ocid" {
  description = "Public subnet OCID"
  type        = string
}

variable "image_path" {
  description = "Path to the built NixOS qcow2 image"
  type        = string
  default     = "../../bootstrap/oci/result/nixos.qcow2"
}
